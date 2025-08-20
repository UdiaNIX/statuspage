#!/bin/bash
set -e # Garante que o script pare imediatamente se um comando falhar.

# Define a variable to control whether to commit changes or not.
commit=true
# Retrieve the URL of the origin remote repository.
origin=$(git remote get-url origin)
# Disable commit if the origin repository matches a specific pattern.
if [[ $origin == *statsig-io/statuspage* ]]; then
  commit=false
fi

# Function to perform health check for a single URL
check_url() {
  local key=$1
  local url=$2
  local commit_enabled=$3
  local status_dir=$4
  local result="failed"

  echo "  -> Checking: $key"

  # Attempt the health check up to 4 times.
  for i in {1..4}; do
    # On retries (i > 1), wait 2 seconds.
    if [ "$i" -gt 1 ]; then
      sleep 2
    fi

    # Perform the curl request with reduced timeouts.
    # The '|| true' prevents 'set -e' from stopping the script on curl errors like timeouts.
    response=$(curl --write-out '%{http_code}' --silent --output /dev/null --connect-timeout 5 --max-time 10 "$url" || true)

    # Check if the response code indicates success.
    if [[ "$response" -eq 200 || "$response" -eq 202 || "$response" -eq 301 || "$response" -eq 302 || "$response" -eq 307 ]]; then
      result="success"
      break # Exit retry loop on success.
    fi
  done

  echo "  <- Finished: $key, Result: $result"
  local dateTime
  dateTime=$(date +'%Y-%m-%d %H:%M')

  # Write the final status to a temporary file for the main process to count failures.
  echo "$result" > "$status_dir/${key}.status"

  # If committing is enabled, append the result to a log file.
  if [[ $commit_enabled == true ]]; then
    echo "$dateTime, $result" >> "logs/${key}_report.log"
    # Keep only the last 2000 log entries.
    echo "$(tail -2000 "logs/${key}_report.log")" > "logs/${key}_report.log"
  else
    # If committing is disabled, print the result to the console.
    echo "    $dateTime, $result"
  fi
}

# Initialize arrays to store keys and URLs from the configuration.
KEYSARRAY=()
URLSARRAY=()

# Specify the configuration file containing URLs to check.
urlsConfig="./urls.cfg"
echo "Reading $urlsConfig"
# Read each line from the configuration file.
while read -r line; do
  echo "  $line"
  # Split each line into key and URL based on the '=' delimiter.
  IFS='=' read -ra TOKENS <<< "$line"
  # Add the key and URL to their respective arrays.
  KEYSARRAY+=(${TOKENS[0]})
  URLSARRAY+=(${TOKENS[1]})
done < "$urlsConfig"

# Create a temporary directory for status files.
status_dir=$(mktemp -d)
# Ensure the temp directory is cleaned up when the script exits.
trap 'rm -rf -- "$status_dir"' EXIT

echo "***********************"
echo "Starting health checks in parallel for ${#KEYSARRAY[@]} configs:"
echo  "node1-id: $NODE1_INSTANCE_ID"
echo  "node2-id: $NODE2_INSTANCE_ID"
echo "***********************"


# Create a directory for logs if it doesn't already exist.
mkdir -p logs

# Launch all checks in the background.
for (( index=0; index < ${#KEYSARRAY[@]}; index++ )); do
  check_url "${KEYSARRAY[index]}" "${URLSARRAY[index]}" "$commit" "$status_dir" &
done

# Wait for all background jobs to complete.
wait
echo "Waiting for all checks to complete..."
wait
echo "All checks completed."

# Count failures by checking the status files.
# 'grep -l' lists files containing "failed", 'wc -l' counts them.
failed_checks=$(grep -l "failed" "$status_dir"/*.status 2>/dev/null | wc -l)

# Create or overwrite a temporary file to indicate the overall health check status.
if [[ $failed_checks -gt 0 ]]; then
  echo "failed" > check_status.tmp
  # Trigger an event to restart instances if any check fails.
  echo "Some checks failed. Triggering instance restart."
  # Check if NODE1_INSTANCE_ID is set and trigger a restart.
  # The NODE1_INSTANCE_ID must be set as an environment variable (e.g., a GitHub Secret).
  if [ -n "$NODE1_INSTANCE_ID" ]; then
    echo "Attempting to SOFTRESET OCI instance NODE1: $NODE1_INSTANCE_ID"
    # A OCI CLI usará automaticamente as
    #    credenciais das variáveis de ambiente (passadas pelo workflow).
    oci compute instance action --action SOFTRESET --instance-id "$NODE1_INSTANCE_ID"
    if [ $? -eq 0 ]; then
      echo "Instance NODE1 restart command issued successfully."
    else
      # Output to stderr to make it more visible in logs
      echo "ERROR: Failed to issue instance NODE1 restart command." >&2
      exit 1 # Falha o build se o comando OCI falhar.
    fi
  else
    echo "WARNING: NODE1_INSTANCE_ID environment variable not set. Skipping instance restart."
  fi

  if [ -n "$NODE2_INSTANCE_ID" ]; then
    echo "Attempting to SOFTRESET OCI instance NODE2: $NODE2_INSTANCE_ID"
    oci compute instance action --action SOFTRESET --instance-id "$NODE2_INSTANCE_ID"
    if [ $? -eq 0 ]; then
      echo "Instance NODE2 restart command issued successfully."
    else
      echo "ERROR: Failed to issue instance NODE2 restart command." >&2
      exit 1
    fi
  fi
  # Garante que o job do GitHub Actions seja marcado como "Failed" se houver falhas.
  exit 1
else
  echo "success" > check_status.tmp
fi

# If committing is enabled, configure Git, commit the log changes, and push to the repository.
if [[ $commit == true ]]; then
  # Configure Git with a generic user name and email.
  git config --global user.name 'Unix-User'
  git config --global user.email 'wevertonslima@gmail.com'

  # Pull latest changes from the remote to avoid push rejections.
  # Using --rebase to maintain a clean, linear history.
  # Assumes the primary branch is 'main'.
  echo "Pulling latest changes from origin main..."
  git pull --rebase origin main

  # Add all changes in the logs directory to the staging area.
  git add -A --force logs/
  # Commit and push only if there are changes to be committed.
  if ! git diff --staged --quiet; then
    echo "Committing and pushing log updates..."
    git commit -m '[Automated] Update Health Check Logs'
    git push
  else
    echo "No log changes to commit."
  fi
fi
