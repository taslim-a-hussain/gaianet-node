#!/bin/bash

# path to the gaianet base directory
gaianet_base_dir="$HOME/gaianet"

# Check if $gaianet_base_dir directory exists
if [ ! -d $gaianet_base_dir ]; then
    printf "\n[Error] Not found $gaianet_base_dir.\n\nPlease run 'bash install_v2.sh' command first, then try again.\n\n"
    exit 1
fi

# check if `log` directory exists or not
if [ ! -d "$gaianet_base_dir/log" ]; then
    mkdir -p $gaianet_base_dir/log
fi
log_dir=$gaianet_base_dir/log

# create or recover a qdrant collection
create_collection() {
    printf "[+] Creating 'default' collection in the Qdrant instance ...\n\n"

    qdrant_pid=0
    qdrant_already_running=false
    if [ "$(uname)" == "Darwin" ] || [ "$(expr substr $(uname -s) 1 5)" == "Linux" ]; then
        if lsof -Pi :6333 -sTCP:LISTEN -t >/dev/null ; then
            printf "    * A Qdrant instance is already running ...\n"
            qdrant_already_running=true
        fi
    elif [ "$(expr substr $(uname -s) 1 10)" == "MINGW32_NT" ]; then
        printf "For Windows users, please run this script in WSL.\n"
        exit 1
    else
        printf "Only support Linux, MacOS and Windows.\n"
        exit 1
    fi

    if [ "$qdrant_already_running" = false ]; then
        printf "    * Start a Qdrant instance ...\n\n"
        # start qdrant
        cd $gaianet_base_dir/qdrant

        # check if `log` directory exists or not
        if [ ! -d "$gaianet_base_dir/log" ]; then
            mkdir -p $gaianet_base_dir/log
        fi
        log_dir=$gaianet_base_dir/log

        nohup $gaianet_base_dir/bin/qdrant > $log_dir/init-qdrant.log 2>&1 &
        sleep 5
        qdrant_pid=$!
    fi

    cd $gaianet_base_dir
    url_snapshot=$(awk -F'"' '/"snapshot":/ {print $4}' config.json)
    url_document=$(awk -F'"' '/"document":/ {print $4}' config.json)
    embedding_collection_name=$(awk -F'"' '/"embedding_collection_name":/ {print $4}' config.json)
    if [[ -z "$embedding_collection_name" ]]; then
        embedding_collection_name="default"
    fi

    printf "    * Remove the existed 'default' Qdrant collection ...\n\n"
    cd $gaianet_base_dir
    # remove the collection if it exists
    del_response=$(curl -s -X DELETE http://localhost:6333/collections/$embedding_collection_name \
        -H "Content-Type: application/json")
    status=$(echo "$del_response" | grep -o '"status":"[^"]*"' | cut -d':' -f2 | tr -d '"')
    if [ "$status" != "ok" ]; then
        printf "      [Error] Failed to remove the $embedding_collection_name collection. $del_response\n\n"

        if [ "$qdrant_already_running" = false ]; then
            kill $qdrant_pid
        fi

        exit 1
    fi

    # 10.1 recover from the given qdrant collection snapshot
    if [ -n "$url_snapshot" ]; then
        printf "    * Download Qdrant collection snapshot ...\n"
        curl --progress-bar -L $url_snapshot -o default.snapshot
        printf "\n"

        printf "    * Import the Qdrant collection snapshot ...\n\n"
        # Import the default.snapshot file
        response=$(curl -s -X POST http://localhost:6333/collections/$embedding_collection_name/snapshots/upload?priority=snapshot \
            -H 'Content-Type:multipart/form-data' \
            -F 'snapshot=@default.snapshot')
        sleep 5

        if echo "$response" | grep -q '"status":"ok"'; then
            rm $gaianet_base_dir/default.snapshot
            printf "    * Recovery is done successfully\n"
        else
            printf "    * [Error] Failed to recover from the collection snapshot. $response \n"

            if [ "$qdrant_already_running" = false ]; then
                kill $qdrant_pid
            fi

            exit 1
        fi

    # 10.2 generate a Qdrant collection from the given document
    elif [ -n "$url_document" ]; then
        printf "    * Create 'default' Qdrant collection from the given document ...\n\n"

        # Start LlamaEdge API Server
        printf "    * Start LlamaEdge-RAG API Server ...\n\n"

        # parse cli options for chat model
        cd $gaianet_base_dir
        url_chat_model=$(awk -F'"' '/"chat":/ {print $4}' config.json)
        # gguf filename
        chat_model_name=$(basename $url_chat_model)
        # stem part of the filename
        chat_model_stem=$(basename "$chat_model_name" .gguf)
        # parse context size for chat model
        chat_ctx_size=$(awk -F'"' '/"chat_ctx_size":/ {print $4}' config.json)
        # parse prompt type for chat model
        prompt_type=$(awk -F'"' '/"prompt_template":/ {print $4}' config.json)
        # parse reverse prompt for chat model
        reverse_prompt=$(awk -F'"' '/"reverse_prompt":/ {print $4}' config.json)
        # parse cli options for embedding model
        url_embedding_model=$(awk -F'"' '/"embedding":/ {print $4}' config.json)
        # gguf filename
        embedding_model_name=$(basename $url_embedding_model)
        # stem part of the filename
        embedding_model_stem=$(basename "$embedding_model_name" .gguf)
        # parse context size for embedding model
        embedding_ctx_size=$(awk -F'"' '/"embedding_ctx_size":/ {print $4}' config.json)
        # parse cli options for embedding vector collection name
        embedding_collection_name=$(awk -F'"' '/"embedding_collection_name":/ {print $4}' config.json)
        if [[ -z "$embedding_collection_name" ]]; then
            embedding_collection_name="default"
        fi
        # parse port for LlamaEdge API Server
        llamaedge_port=$(awk -F'"' '/"llamaedge_port":/ {print $4}' config.json)

        if [ "$(uname)" == "Darwin" ] || [ "$(expr substr $(uname -s) 1 5)" == "Linux" ]; then
            if lsof -Pi :$llamaedge_port -sTCP:LISTEN -t >/dev/null ; then
                printf "It appears that the GaiaNet node is running. Please stop it first.\n\n"

                if [ "$qdrant_already_running" = false ]; then
                    kill $qdrant_pid
                fi

                exit 1
            fi
        elif [ "$(expr substr $(uname -s) 1 10)" == "MINGW32_NT" ]; then
            printf "For Windows users, please run this script in WSL.\n"

            if [ "$qdrant_already_running" = false ]; then
                kill $qdrant_pid
            fi

            exit 1
        else
            printf "Only support Linux, MacOS and Windows.\n"

            if [ "$qdrant_already_running" = false ]; then
                kill $qdrant_pid
            fi

            exit 1
        fi

        # command to start LlamaEdge API Server
        cd $gaianet_base_dir
        cmd="wasmedge --dir .:. \
        --nn-preload default:GGML:AUTO:$chat_model_name \
        --nn-preload embedding:GGML:AUTO:$embedding_model_name \
        rag-api-server.wasm -p $prompt_type \
        --model-name $chat_model_stem,$embedding_model_stem \
        --ctx-size $chat_ctx_size,$embedding_ctx_size \
        --qdrant-collection-name $embedding_collection_name \
        --web-ui ./dashboard \
        --socket-addr 0.0.0.0:$llamaedge_port \
        --log-prompts \
        --log-stat"

        # printf "    Run the following command to start the LlamaEdge API Server:\n\n"
        # printf "    %s\n\n" "$cmd"

        nohup $cmd > $log_dir/init-qdrant-gen-collection.log 2>&1 &
        sleep 5
        llamaedge_pid=$!
        echo $llamaedge_pid > $gaianet_base_dir/llamaedge.pid

        printf "    * Convert document to embeddings ...\n"
        printf "      The process may take a few minutes. Please wait ...\n\n"
        cd $gaianet_base_dir
        doc_filename=$(basename $url_document)
        curl -s $url_document -o $doc_filename

        if [[ $doc_filename != *.txt ]] && [[ $doc_filename != *.md ]]; then
            printf "Error: the document to upload should be a file with 'txt' or 'md' extension.\n"

            # stop the api-server
            if [ -f "$gaianet_base_dir/llamaedge.pid" ]; then
                # printf "[+] Stopping API server ...\n"
                kill $(cat $gaianet_base_dir/llamaedge.pid)
                rm $gaianet_base_dir/llamaedge.pid
            fi

            if [ "$qdrant_already_running" = false ]; then
                kill $qdrant_pid
            fi

            exit 1
        fi

        # compute embeddings
        embedding_response=$(curl -s -X POST http://127.0.0.1:$llamaedge_port/v1/create/rag -F "file=@$doc_filename")

        # remove the downloaded document
        rm -f $gaianet_base_dir/$doc_filename

        # stop the api-server
        if [ -f "$gaianet_base_dir/llamaedge.pid" ]; then
            # stop API server
            kill $(cat $gaianet_base_dir/llamaedge.pid)
            rm $gaianet_base_dir/llamaedge.pid
        fi

        if [ -z "$embedding_response" ]; then
            printf "    * [Error] Failed to compute embeddings. Exit ...\n"

            if [ "$qdrant_already_running" = false ]; then
                kill $qdrant_pid
            fi

            exit 1
        else
            printf "    * Embeddings are computed successfully\n"
        fi

    else
        echo "Please set 'snapshot' or 'document' field in config.json"
    fi
    printf "\n"

    if [ "$qdrant_already_running" = false ]; then
        # stop qdrant
        kill $qdrant_pid
    fi

}

init() {
    # download GGUF chat model file to $gaianet_base_dir
    url_chat_model=$(awk -F'"' '/"chat":/ {print $4}' $gaianet_base_dir/config.json)
    chat_model=$(basename $url_chat_model)
    if [ -f "$gaianet_base_dir/$chat_model" ]; then
        printf "[+] Using the cached chat model: $chat_model\n"
    else
        printf "[+] Downloading $chat_model ...\n"
        curl --retry 3 --progress-bar -L $url_chat_model -o $gaianet_base_dir/$chat_model
    fi
    printf "\n"

    # download GGUF embedding model file to $gaianet_base_dir
    url_embedding_model=$(awk -F'"' '/"embedding":/ {print $4}' $gaianet_base_dir/config.json)
    embedding_model=$(basename $url_embedding_model)
    if [ -f "$gaianet_base_dir/$embedding_model" ]; then
        printf "[+] Using the cached embedding model: $embedding_model\n"
    else
        printf "[+] Downloading $embedding_model ...\n\n"
        curl --retry 3 --progress-bar -L $url_embedding_model -o $gaianet_base_dir/$embedding_model
    fi
    printf "\n"

    # create or recover a qdrant collection
    create_collection
}

# * config subcommand
update_config() {
    key=$1
    new_value=$2
    file=$gaianet_base_dir/config.json
    bak=$gaianet_base_dir/config.json.bak
    # update in place
    sed -i.bak -e "/\"$key\":/ s#: \".*\"#: \"$new_value\"#" $file
    # remove backup file
    rm $bak
}

update_config_system_prompt() {
    key=$1
    new_value=$2
    file=$gaianet_base_dir/config.json
    bak=$gaianet_base_dir/config.json.bak
    sed -i.bak -e "s#\(\"$key\": \).*#\1\"$new_value\"#" $file
    rm $bak
}

# * start subcommand

# start rag-api-server and a qdrant instance
start() {

    # Check if "gaianet" home directory exists
    if [ ! -d "$gaianet_base_dir" ]; then
        printf "Not found $gaianet_base_dir\n"
        exit 1
    fi

    # check if `log` directory exists or not
    if [ ! -d "$gaianet_base_dir/log" ]; then
        mkdir -p $gaianet_base_dir/log
    fi
    log_dir=$gaianet_base_dir/log

    # check if config.json exists or not
    if [ ! -f "$gaianet_base_dir/config.json" ]; then
        printf "config.json file not found in $gaianet_base_dir\n"
        exit 1
    fi


    # 1. start a Qdrant instance
    printf "[+] Starting Qdrant instance ...\n"

    qdrant_already_running=false
    if [ "$(uname)" == "Darwin" ] || [ "$(expr substr $(uname -s) 1 5)" == "Linux" ]; then
        if lsof -Pi :6333 -sTCP:LISTEN -t >/dev/null ; then
            # printf "    Port 6333 is in use. Stopping the process on 6333 ...\n\n"
            # pid=$(lsof -t -i:6333)
            # kill -9 $pid
            qdrant_already_running=true
        fi
    elif [ "$(expr substr $(uname -s) 1 10)" == "MINGW32_NT" ]; then
        printf "For Windows users, please run this script in WSL.\n"
        exit 1
    else
        printf "Only support Linux, MacOS and Windows.\n"
        exit 1
    fi

    if [ "$qdrant_already_running" = false ]; then
        qdrant_executable="$gaianet_base_dir/bin/qdrant"
        if [ -f "$qdrant_executable" ]; then
            cd $gaianet_base_dir/qdrant
            nohup $qdrant_executable > $log_dir/start-qdrant.log 2>&1 &
            sleep 2
            qdrant_pid=$!
            echo $qdrant_pid > $gaianet_base_dir/qdrant.pid
            printf "\n    Qdrant instance started with pid: $qdrant_pid\n\n"
        else
            printf "Qdrant binary not found at $qdrant_executable\n\n"
            exit 1
        fi
    fi

    # 2. start a LlamaEdge instance
    printf "[+] Starting LlamaEdge API Server ...\n\n"

    # We will make sure that the path is setup in case the user runs start.sh immediately after init.sh
    source $HOME/.wasmedge/env

    # parse cli options for chat model
    cd $gaianet_base_dir
    url_chat_model=$(awk -F'"' '/"chat":/ {print $4}' config.json)
    # gguf filename
    chat_model_name=$(basename $url_chat_model)
    # stem part of the filename
    chat_model_stem=$(basename "$chat_model_name" .gguf)
    # parse context size for chat model
    chat_ctx_size=$(awk -F'"' '/"chat_ctx_size":/ {print $4}' config.json)
    # parse prompt type for chat model
    prompt_type=$(awk -F'"' '/"prompt_template":/ {print $4}' config.json)
    # parse system prompt for chat model
    rag_prompt=$(awk -F'"' '/"rag_prompt":/ {print $4}' config.json)
    # parse reverse prompt for chat model
    reverse_prompt=$(awk -F'"' '/"reverse_prompt":/ {print $4}' config.json)
    # parse cli options for embedding model
    url_embedding_model=$(awk -F'"' '/"embedding":/ {print $4}' config.json)
    # parse cli options for embedding vector collection name
    embedding_collection_name=$(awk -F'"' '/"embedding_collection_name":/ {print $4}' config.json)
    if [[ -z "$embedding_collection_name" ]]; then
        embedding_collection_name="default"
    fi
    # gguf filename
    embedding_model_name=$(basename $url_embedding_model)
    # stem part of the filename
    embedding_model_stem=$(basename "$embedding_model_name" .gguf)
    # parse context size for embedding model
    embedding_ctx_size=$(awk -F'"' '/"embedding_ctx_size":/ {print $4}' config.json)
    # parse port for LlamaEdge API Server
    llamaedge_port=$(awk -F'"' '/"llamaedge_port":/ {print $4}' config.json)

    if [ "$(uname)" == "Darwin" ] || [ "$(expr substr $(uname -s) 1 5)" == "Linux" ]; then
        if lsof -Pi :$llamaedge_port -sTCP:LISTEN -t >/dev/null ; then
            printf "    Port $llamaedge_port is in use. Stopping the process on $llamaedge_port ...\n\n"
            pid=$(lsof -t -i:$llamaedge_port)
            kill $pid
        fi
    elif [ "$(expr substr $(uname -s) 1 10)" == "MINGW32_NT" ]; then
        printf "For Windows users, please run this script in WSL.\n"
        exit 1
    else
        printf "Only support Linux, MacOS and Windows.\n"
        exit 1
    fi

    cd $gaianet_base_dir
    llamaedge_wasm="$gaianet_base_dir/rag-api-server.wasm"
    if [ ! -f "$llamaedge_wasm" ]; then
        printf "LlamaEdge wasm not found at $llamaedge_wasm\n"
        exit 1
    fi

    # command to start LlamaEdge API Server
    cd $gaianet_base_dir
    cmd=(wasmedge --dir .:./dashboard \
    --nn-preload default:GGML:AUTO:$chat_model_name \
    --nn-preload embedding:GGML:AUTO:$embedding_model_name \
    rag-api-server.wasm \
    --model-name $chat_model_stem,$embedding_model_stem \
    --ctx-size $chat_ctx_size,$embedding_ctx_size \
    --prompt-template $prompt_type \
    --qdrant-collection-name $embedding_collection_name \
    --web-ui ./ \
    --socket-addr 0.0.0.0:$llamaedge_port \
    --log-prompts \
    --log-stat)

    # Add system prompt if it exists
    if [ -n "$rag_prompt" ]; then
        cmd+=("--rag-prompt" "$rag_prompt")
    fi

    # Add reverse prompt if it exists
    if [ -n "$reverse_prompt" ]; then
        cmd+=("--reverse_prompt" "$reverse_prompt")
    fi

    printf "    Run the following command to start the LlamaEdge API Server:\n\n"
    for i in "${cmd[@]}"; do
        if [[ $i == *" "* ]]; then
            printf "\"%s\" " "$i"
        else
            printf "%s " "$i"
        fi
    done
    printf "\n\n"

    # eval $cmd
    nohup "${cmd[@]}" > $log_dir/start-llamaedge.log 2>&1 &
    sleep 2
    llamaedge_pid=$!
    echo $llamaedge_pid > $gaianet_base_dir/llamaedge.pid
    printf "\n    LlamaEdge API Server started with pid: $llamaedge_pid\n\n"

    # if [ "$local_only" -eq 0 ]; then
    #     # start gaianet-domain
    #     printf "[+] Starting gaianet-domain ...\n"
    #     nohup $gaianet_base_dir/bin/frpc -c $gaianet_base_dir/gaianet-domain/frpc.toml > $log_dir/start-gaianet-domain.log 2>&1 &
    #     sleep 2
    #     gaianet_domain_pid=$!
    #     echo $gaianet_domain_pid > $gaianet_base_dir/gaianet-domain.pid
    #     printf "\n    gaianet-domain started with pid: $gaianet_domain_pid\n\n"

    #     # Extract the subdomain from frpc.toml
    #     subdomain=$(grep "subdomain" $gaianet_base_dir/gaianet-domain/frpc.toml | cut -d'=' -f2 | tr -d ' "')
    #     printf "    The GaiaNet node is started at: https://$subdomain.gaianet.xyz\n"
    # fi
    # if [ "$local_only" -eq 1 ]; then
    #     printf "    The GaiaNet node is started in local mode at: http://localhost:$llamaedge_port\n"
    # fi
    # printf "\n>>> To stop Qdrant instance and LlamaEdge API Server, run the command: ./stop.sh <<<\n"

    exit 0


}

# * stop subcommand

# stop the Qdrant instance, rag-api-server, and gaianet-domain
stop() {

    # Check if "gaianet" directory exists in $HOME
    if [ ! -d "$gaianet_base_dir" ]; then
        printf "Not found $gaianet_base_dir\n"
        exit 1
    fi

    # stop the Qdrant instance
    qdrant_pid=$gaianet_base_dir/qdrant.pid
    if [ -f $qdrant_pid ]; then
        printf "[+] Stopping Qdrant instance ...\n"
        kill -9 $(cat $qdrant_pid)
        rm $qdrant_pid
    fi

    # stop the api-server
    llamaedge_pid=$gaianet_base_dir/llamaedge.pid
    if [ -f $llamaedge_pid ]; then
        printf "[+] Stopping API server ...\n"
        kill -9 $(cat $llamaedge_pid)
        rm $llamaedge_pid
    fi

    # stop gaianet-domain
    gaianet_domain_pid=$gaianet_base_dir/gaianet-domain.pid
    if [ -f $gaianet_domain_pid ]; then
        printf "[+] Stopping gaianet-domain ...\n"
        kill -9 $(cat $gaianet_domain_pid)
        rm $gaianet_domain_pid
    fi

    exit 0

}

# force stop the Qdrant instance, rag-api-server, and gaianet-domain
stop_force() {
    printf "Force stopping WasmEdge, Qdrant and frpc processes ...\n"
    pkill -9 wasmedge
    pkill -9 qdrant
    pkill -9 frpc

    qdrant_pid=$gaianet_base_dir/qdrant.pid
    if [ -f $qdrant_pid ]; then
        rm $qdrant_pid
    fi

    llamaedge_pid=$gaianet_base_dir/llamaedge.pid
    if [ -f $llamaedge_pid ]; then
        rm $llamaedge_pid
    fi

    gaianet_domain_pid=$gaianet_base_dir/gaianet-domain.pid
    if [ -f $gaianet_domain_pid ]; then
        rm $gaianet_domain_pid
    fi

    exit 0
}

# * help option

show_help() {
    printf "Usage: $0 {config|init|run|stop} [arg]\n\n"
    printf "Subcommands:\n"
    printf "  config <arg>  Update the configuration.
                Available args: chat_url, chat_ctx_size, embedding_url, embedding_ctx_size, system_prompt\n"
    printf "  init [arg]    Initialize with optional argument.
                Available args: paris_guide, berkeley_cs_101_ta, vitalik_buterin, <url-to-config.json>\n"
    printf "  run           Run the program\n"
    printf "  stop [arg]    Stop the program.
                Available args: --force\n"
    printf "\nOptions:\n"
    printf "  --help        Show this help message\n\n"
}

# * main

subcommand=$1
arg=$2
val=$3
shift 3

case $subcommand in
    --help)
        show_help
        ;;
    config)
        case $arg in
            chat_url)
                printf "[+] Updating the url of chat model ...\n"
                printf "    * Old url: $(awk -F'"' '/"chat":/ {print $4}' $gaianet_base_dir/config.json)\n"
                printf "    * New url: $val\n\n"

                # update
                update_config chat $val

                ;;
            chat_ctx_size)
                printf "[+] Updating the context size of chat model ...\n"
                printf "    * Old size: $(awk -F'"' '/"chat_ctx_size":/ {print $4}' $gaianet_base_dir/config.json)\n"
                printf "    * New size: $val\n\n"

                # update
                update_config chat_ctx_size $val

                ;;
            embedding_url)
                printf "[+] Updating the url of embedding model ...\n"
                printf "    * Old url: $(awk -F'"' '/"embedding":/ {print $4}' $gaianet_base_dir/config.json)\n"
                printf "    * New url: $val\n\n"

                # update
                update_config embedding $val

                ;;
            embedding_ctx_size)
                printf "[+] Updating the context size of embedding model ...\n"
                printf "    * Old size: $(awk -F'"' '/"embedding_ctx_size":/ {print $4}' $gaianet_base_dir/config.json)\n"
                printf "    * New size: $val\n\n"

                # update
                update_config embedding_ctx_size $val

                ;;
            system_prompt)
                echo "value: $val"

                printf "[+] Updating system prompt ...\n"
                printf "    * Old size: $(awk -F'"' '/"system_prompt":/ {print $4}' $gaianet_base_dir/config.json)\n"
                printf "    * New size: $val\n\n"

                # update
                # update_config system_prompt $val
                update_config_system_prompt system_prompt $val

                ;;
            *)
                # init
                init

                ;;
        esac
        ;;
    init)
        case $arg in
            paris_guide)
                echo "todo: Prepare Paris guide"
                ;;
            berkeley_cs_101_ta)
                echo "todo: Berkeley"
                ;;
            vitalik_buterin)
                echo "todo: Vitalik Buterin"
                ;;
            *config.json)
                printf "[+] Downloading config.json ...\n"
                printf "    Url: $arg\n"

                cd $gaianet_base_dir
                curl --retry 3 --progress-bar -L $arg -o config.json
                ;;
            *)
                # init
                init
                ;;
        esac
        ;;
    run)
        # start rag-api-server and a qdrant instance
        start

        ;;
    stop)
        case $arg in
            --force)
                # force stop the Qdrant instance, rag-api-server, and gaianet-domain
                stop_force
                ;;
            *)
                # stop the Qdrant instance, rag-api-server, and gaianet-domain
                stop

                ;;
        esac
        ;;
    *)
        show_help
        exit 1
esac

