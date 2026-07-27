{ pkgs }:
pkgs.writeShellScript "monitoring-lite-send-notify.sh" ''
  set -euo pipefail

  provider=""
  status=""
  url_file=""
  message=""
  token_file=""
  auth_header=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --provider) provider="$2"; shift 2 ;;
      --status) status="$2"; shift 2 ;;
      --url-file) url_file="$2"; shift 2 ;;
      --message) message="$2"; shift 2 ;;
      --token-file) token_file="$2"; shift 2 ;;
      --auth-header) auth_header="$2"; shift 2 ;;
      *)
        echo "unknown argument: $1" >&2
        exit 2
        ;;
    esac
  done

  if [ -z "$provider" ] || [ -z "$status" ] || [ -z "$url_file" ]; then
    echo "missing required arguments: --provider --status --url-file" >&2
    exit 2
  fi

  base_url="$(${pkgs.coreutils}/bin/cat "$url_file")"
  url="$base_url"
  case "$provider" in
    healthchecks)
      if [ "$status" = "fail" ]; then
        url="$base_url/fail"
      fi
      ;;
    *)
      echo "unsupported provider: $provider" >&2
      exit 2
      ;;
  esac

  curl_args=(
    -fsS
    -m 15
    --retry 5
    -o /dev/null
  )
  if [ -n "$auth_header" ] && [ -n "$token_file" ]; then
    token="$(${pkgs.coreutils}/bin/cat "$token_file")"
    curl_args+=(-H "$auth_header: $token")
  fi

  ${pkgs.curl}/bin/curl "''${curl_args[@]}" --data-raw "$message" "$url"
''
