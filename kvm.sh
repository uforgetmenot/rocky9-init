#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVM_DIR="$SCRIPT_DIR/kvm/rocky9"

get_yq() {
    if command -v yq >/dev/null 2>&1; then
        echo "yq"
        return 0
    fi

    local bundled_yq="$SCRIPT_DIR/assets/tools/yq_linux_amd64"
    if [[ -x "$bundled_yq" ]]; then
        echo "$bundled_yq"
        return 0
    fi

    return 1
}

get_compose_host_port() {
    local index="$1"
    local label="$2"
    local compose_file="$KVM_DIR/docker-compose.yml"
    local yq_cmd
    yq_cmd="$(get_yq)" || {
        echo "error: yq not found (install yq or make $SCRIPT_DIR/assets/tools/yq_linux_amd64 executable)" >&2
        return 1
    }

    local mapping
    mapping="$($yq_cmd -r ".services.kvm.ports[$index]" "$compose_file")" || return 1
    if [[ -z "$mapping" || "$mapping" == "null" ]]; then
        echo "error: could not read .services.kvm.ports[$index] ($label) from $compose_file" >&2
        return 1
    fi

    mapping="${mapping%%/*}"

    local -a parts
    IFS=':' read -r -a parts <<<"$mapping"

    local host_port=""
    if [[ ${#parts[@]} -eq 3 ]]; then
        host_port="${parts[1]}"
    elif [[ ${#parts[@]} -eq 2 ]]; then
        host_port="${parts[0]}"
    elif [[ ${#parts[@]} -eq 1 ]]; then
        host_port="${parts[0]}"
    fi

    if [[ ! "$host_port" =~ ^[0-9]+$ ]]; then
        echo "error: unexpected port mapping format for $label: $mapping" >&2
        return 1
    fi

    echo "$host_port"
}

get_vnc_port() {
    get_compose_host_port 2 "VNC"
}

get_ssh_port() {
    get_compose_host_port 3 "SSH"
}

ensure_ssh_config_host() {
    local host_alias="$1"
    local ssh_port="$2"
    local ssh_user="$3"

    local ssh_dir="$HOME/.ssh"
    local ssh_config="$ssh_dir/config"

    mkdir -p "$ssh_dir" || return 1
    touch "$ssh_config" || return 1

    if grep -qE "^Host[[:space:]]+$host_alias([[:space:]]|$)" "$ssh_config"; then
        # Best-effort: don't mutate an existing user-managed host entry.
        return 0
    fi

    {
        echo
        echo "Host $host_alias"
        echo "  HostName localhost"
        echo "  Port $ssh_port"
        echo "  User $ssh_user"
        echo "  StrictHostKeyChecking no"
        echo "  UserKnownHostsFile /dev/null"
    } >>"$ssh_config"
}

select_command() {
    local options=(start stop status shell logs vnc ssh vscode quit)
    while true; do
        echo "Available commands:"
        local i=1
        for opt in "${options[@]}"; do
            echo "$i) $opt"
            ((i++))
        done

        local reply
        read -r -p "Select a command (number or name): " reply || return 1

        reply="${reply#"${reply%%[![:space:]]*}"}"
        reply="${reply%"${reply##*[![:space:]]}"}"

        if [[ -z "$reply" ]]; then
            echo "Invalid selection. Try again." >&2
            continue
        fi

        if [[ "$reply" =~ ^[0-9]+$ ]]; then
            local idx=$((reply - 1))
            if (( idx >= 0 && idx < ${#options[@]} )); then
                local cmd="${options[$idx]}"
                if [[ "$cmd" == "quit" ]]; then
                    return 1
                fi
                COMMAND="$cmd"
                return 0
            fi
        else
            for opt in "${options[@]}"; do
                if [[ "$reply" == "$opt" ]]; then
                    if [[ "$opt" == "quit" ]]; then
                        return 1
                    fi
                    COMMAND="$opt"
                    return 0
                fi
            done
        fi

        echo "Invalid selection. Try again." >&2
    done
}

COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
    if ! select_command; then
        exit 0
    fi
fi

case "$COMMAND" in
    start)
        echo "Starting KVM Rocky9..."
        cd "$KVM_DIR" && docker compose up -d
        ;;
    stop)
        echo "Stopping KVM Rocky9..."
        cd "$KVM_DIR" && docker compose stop
        ;;
    status)
        cd "$KVM_DIR" && docker compose ps
        ;;
    shell)
        cd "$KVM_DIR" && docker compose exec kvm /bin/bash
        ;;
    logs)
        cd "$KVM_DIR" && docker compose logs "${@:2}"
        ;;
    vnc)
        vnc_port="$(get_vnc_port)" || exit 1
        echo "Connecting to VNC on localhost:$vnc_port ..."
        vncviewer "localhost::$vnc_port"
        ;;
    ssh)
        ssh_port="$(get_ssh_port)" || exit 1
        ssh_user="${2:-virtualink}"
        echo "To copy your SSH public key into the VM, run:"
        echo "  ssh-copy-id -i ~/.ssh/id_rsa.pub -p $ssh_port ${ssh_user}@localhost"

        echo "Connecting to SSH on localhost:$ssh_port as $ssh_user ..."
        ssh -p "$ssh_port" "${ssh_user}@localhost" "${@:3}"
        ;;
    vscode)
        if ! command -v code >/dev/null 2>&1; then
            echo "error: VS Code 'code' command not found in PATH" >&2
            exit 1
        fi

        ssh_port="$(get_ssh_port)" || exit 1
        ssh_user="${2:-virtualink}"
        host_alias="${3:-localhost}"
        remote_dir="${4:-/home/$ssh_user/work}"
        if [[ "$ssh_user" == "root" ]]; then
            remote_dir="${4:-/root/work}"
        fi

        ensure_ssh_config_host "$host_alias" "$ssh_port" "$ssh_user" || exit 1

        if ! command -v ssh >/dev/null 2>&1; then
            echo "error: 'ssh' command not found in PATH (required to ensure remote directory exists: $remote_dir)" >&2
            exit 1
        fi

        if [[ -z "$remote_dir" ]]; then
            echo "error: remote_dir is empty" >&2
            exit 1
        fi

        remote_dir_escaped="${remote_dir//\'/\'\\\'\'}"

        if ! ssh -p "$ssh_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${ssh_user}@${host_alias}" \
            "mkdir -p -- '$remote_dir_escaped'"
        then
            echo "error: failed to ensure remote directory exists: $remote_dir" >&2
            exit 1
        fi

        echo "Opening VS Code Remote-SSH: $host_alias:$remote_dir with user $ssh_user in port $ssh_port ..."
        # rm -f ~/.ssh/known_hosts
        code --folder-uri="vscode-remote://ssh-remote+${ssh_user}@${host_alias}:${ssh_port}${remote_dir}"
        ;;
    *)
        echo "Usage: ./kvm.sh <start|stop|status|shell|logs|vnc|ssh|vscode>"
        echo "  logs: passes extra args to docker compose logs"
        echo "  ssh:  ./kvm.sh ssh [user] [extra ssh args...]"
        echo "  vscode: ./kvm.sh vscode [user] [host-alias] [remote-dir]"
        echo "Or run without arguments for an interactive menu."
        exit 1
        ;;
esac
