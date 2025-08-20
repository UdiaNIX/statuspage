#!/bin/bash
set -e # 1. Garante que o script pare imediatamente se um comando falhar.

# Define a variable to control whether to commit changes or not.
commit=true
# Retrieve the URL of the origin remote repository.
origin=$(git remote get-url origin)
# Disable commit if the origin repository matches a specific pattern.
if [[ $origin == *statsig-io/statuspage* ]]
then
  commit=false
fi

# Initialize arrays to store keys and URLs from the configuration.
KEYSARRAY=()
URLSARRAY=()

# Specify the configuration file containing URLs to check.
urlsConfig="./urls.cfg"
echo "Reading $urlsConfig"
# Read each line from the configuration file.
while read -r line
do
  echo "  $line"
  # Split each line into key and URL based on the '=' delimiter.
  IFS='=' read -ra TOKENS <<< "$line"
  # Add the key and URL to their respective arrays.
  KEYSARRAY+=(${TOKENS[0]})
  URLSARRAY+=(${TOKENS[1]})
done < "$urlsConfig"

echo "***********************"
echo "Starting health checks with ${#KEYSARRAY[@]} configs:"

# Create a directory for logs if it doesn't already exist.
mkdir -p logs

# Initialize a counter for failed checks.
failed_checks=0

# Iterate over the array of keys and URLs to perform health checks.
for (( index=0; index < ${#KEYSARRAY[@]}; index++))
do
  key="${KEYSARRAY[index]}"
  url="${URLSARRAY[index]}"
  echo "  $key=$url"

  # Attempt the health check 4 times for each URL.
  for i in 1 2 3 4; 
  do
    # Send a request to the URL and capture the HTTP response code.
    response=$(curl --write-out '%{http_code}' --silent --output /dev/null $url)
    # Check if the response code indicates success.
    if [ "$response" -eq 200 ] || [ "$response" -eq 202 ] || [ "$response" -eq 301 ] || [ "$response" -eq 302 ] || [ "$response" -eq 307 ]; then
      result="success"
    else
      result="failed"
      # Increment the failed checks counter if the check fails.
      failed_checks=$((failed_checks + 1))
    fi
    # If the check is successful, exit the retry loop.
    if [ "$result" = "success" ]; then
      break
    fi
    # Wait for 5 seconds before retrying.
    sleep 5
  done
  # Record the date and time of the check.
  dateTime=$(date +'%Y-%m-%d %H:%M')
  # If committing is enabled, append the result to a log file and keep the last 2000 entries.
  if [[ $commit == true ]]
  then
    echo $dateTime, $result >> "logs/${key}_report.log"
    # Keep only the last 2000 log entries for each key.
    echo "$(tail -2000 logs/${key}_report.log)" > "logs/${key}_report.log"
  else
    # If committing is disabled, print the result to the console.
    echo "    $dateTime, $result"
  fi
done

# Create or overwrite a temporary file to indicate the overall health check status.
if [[ $failed_checks -gt 0 ]]
then
  echo "failed" > check_status.tmp
  # Trigger an event to restart instances if any check fails.
  echo "Some checks failed. Triggering instance restart."
  # Check if OCI_INSTANCE_ID is set and trigger a restart.
  # The OCI_INSTANCE_ID must be set as an environment variable (e.g., a GitHub Secret).
  if [ -n "$OCI_INSTANCE_ID" ]; then
    echo "Attempting to SOFTRESET OCI instance: $OCI_INSTANCE_ID"
    # 2. A flag '--auth' foi removida. A OCI CLI usará automaticamente as
    #    credenciais das variáveis de ambiente (passadas pelo workflow).
    oci compute instance action --action SOFTRESET --instance-id "$OCI_INSTANCE_ID"
    if [ $? -eq 0 ]; then
      echo "Instance restart command issued successfully."
    else
      # Output to stderr to make it more visible in logs
      echo "ERROR: Failed to issue instance restart command." >&2
      exit 1 # 3. Falha o build se o comando OCI falhar.
    fi
  else
    echo "WARNING: OCI_INSTANCE_ID environment variable not set. Skipping instance restart."
  fi
  # 4. Garante que o job do GitHub Actions seja marcado como "Failed" se houver falhas.
  exit 1
else
  echo "success" > check_status.tmp
fi

# If committing is enabled, configure Git, commit the log changes, and push to the repository.
if [[ $commit == true ]]
then
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
