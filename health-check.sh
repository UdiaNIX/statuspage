name: Health Check and OCI Instance Restart

on:
  schedule:
    - cron: '*/5 * * * *'  # Executa a cada 5 minutos
  workflow_dispatch:        # Permite execução manual

env:
  OCI_CLI_USER: ${{ secrets.OCI_USER_OCID }}
  OCI_CLI_FINGERPRINT: ${{ secrets.OCI_FINGERPRINT }}
  OCI_CLI_TENANCY: ${{ secrets.OCI_TENANCY_OCID }}
  OCI_CLI_REGION: ${{ secrets.OCI_REGION }}
  OCI_CLI_KEY_CONTENT: ${{ secrets.OCI_KEY_FILE }}

jobs:
  health-check:
    runs-on: ubuntu-latest
    
    steps:
    - name: Checkout repository
      uses: actions/checkout@v4

    - name: Setup OCI CLI
      run: |
        # Instalar OCI CLI
        bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" --accept-all-defaults
        echo "$HOME/bin" >> $GITHUB_PATH

    - name: Configure OCI CLI
      run: |
        mkdir -p ~/.oci
        # Criar arquivo de configuração
        cat > ~/.oci/config << EOF
        [DEFAULT]
        user=$OCI_CLI_USER
        fingerprint=$OCI_CLI_FINGERPRINT
        tenancy=$OCI_CLI_TENANCY
        region=$OCI_CLI_REGION
        key_file=~/.oci/oci_api_key.pem
        EOF
        
        # Criar arquivo de chave privada
        echo "$OCI_CLI_KEY_CONTENT" > ~/.oci/oci_api_key.pem
        chmod 600 ~/.oci/oci_api_key.pem

    - name: Run Health Check Script
      run: |
        chmod +x healthcheck.sh
        ./healthcheck.sh
      env:
        NODE1_INSTANCE_ID: ${{ secrets.NODE1_INSTANCE_ID }}
        NODE2_INSTANCE_ID: ${{ secrets.NODE2_INSTANCE_ID }}

    - name: Upload Logs on Failure
      if: failure()
      uses: actions/upload-artifact@v4
      with:
        name: healthcheck-logs
        path: logs/

    - name: Send Notification on Failure
      if: failure()
      uses: actions-hub/slack@master
      env:
        SLACK_TOKEN: ${{ secrets.SLACK_TOKEN }}
        SLACK_CHANNEL: '#alerts'
        SLACK_USERNAME: 'Health Check Bot'
        SLACK_MESSAGE: 'Health check failed! Instance ${{ secrets.NODE1_INSTANCE_ID }} was restarted.'