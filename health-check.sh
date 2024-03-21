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
  # The actual restart logic is handled in the .github/workflows/health-check.yml file.
else
  echo "success" > check_status.tmp
fi

# If committing is enabled, configure Git, commit the log changes, and push to the repository.
if [[ $commit == true ]]
then
  # Configure Git with a generic user name and email.
  git config --global user.name 'Unix-User'
  git config --global user.email 'wevertonslima@gmail.com'
  # Add all changes in the logs directory to the staging area and commit them.
  git add -A --force logs/
  git commit -am '[Automated] Update Health Check Logs'
  # Push the commit to the remote repository.
  git push
fi
