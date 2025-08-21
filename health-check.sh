#!/bin/bash
set -e # Garante que o script pare imediatamente se um comando falhar.

# Função para configurar a autenticação OCI a partir de variáveis de ambiente.
# Isso é necessário porque a chave privada precisa ser escrita em um arquivo.
setup_oci_auth() {
  # Verifica se o conteúdo da chave OCI foi passado.
  if [ -z "$OCI_CLI_KEY_CONTENT" ]; then
    # Se não houver chave, não podemos prosseguir com comandos OCI.
    # Não saímos do script, pois os checks de URL ainda podem ser úteis.
    echo "AVISO: OCI_CLI_KEY_CONTENT não está definida. Comandos OCI serão pulados."
    return
  fi

  # Cria o diretório de configuração da OCI se não existir.
  mkdir -p ~/.oci
  # Define o caminho para o arquivo da chave privada.
  local oci_key_file=~/.oci/oci_api_key.pem
  # Escreve o conteúdo da chave (passado via env var) no arquivo.
  echo "$OCI_CLI_KEY_CONTENT" > "$oci_key_file"
  # Define permissões restritas para o arquivo da chave.
  chmod 600 "$oci_key_file"
  # Exporta a variável de ambiente que o OCI CLI usa para encontrar o arquivo da chave.
  export OCI_CLI_KEY_FILE="$oci_key_file"
}

# Carrega variáveis de ambiente do arquivo .env, se existir
if [ -f .env ]; then
  echo "Carregando variáveis de ambiente do arquivo .env"
  set -o allexport
  source .env
  set +o allexport
fi

# Chama a função de setup da OCI no início do script.
setup_oci_auth

# Define uma variável para controlar se deve commitar mudanças ou não.
commit=true
# Recupera a URL do repositório remoto origin.
origin=$(git remote get-url origin)
# Desabilita commit se o repositório de origem corresponder a um padrão específico.
if [[ $origin == *statsig-io/statuspage* ]]; then
  commit=false
fi

# Função para realizar health check de uma única URL
check_url() {
  local key=$1
  local url=$2
  local commit_enabled=$3
  local status_dir=$4
  local result="failed"

  echo "  -> Checando: $key"

  # Tenta o health check até 4 vezes.
  for i in {1..4}; do
    # Em tentativas (i > 1), espera 2 segundos.
    if [ "$i" -gt 1 ]; then
      sleep 2
    fi

    # Realiza o curl com timeouts reduzidos.
    # O '|| true' previne que o 'set -e' pare o script em erros do curl.
    response=$(curl --write-out '%{http_code}' --silent --output /dev/null --connect-timeout 5 --max-time 10 "$url" || true)

    # Verifica se o código de resposta indica sucesso.
    if [[ "$response" -eq 200 || "$response" -eq 202 || "$response" -eq 301 || "$response" -eq 302 || "$response" -eq 307 ]]; then
      result="success"
      break # Sai do loop de tentativas em caso de sucesso.
    fi
  done

  echo "  <- Finalizado: $key, Resultado: $result"
  local dateTime
  dateTime=$(date +'%Y-%m-%d %H:%M')

  # Escreve o status final em um arquivo temporário para o processo principal contar falhas.
  echo "$result" > "$status_dir/${key}.status"

  # Se commit estiver habilitado, adiciona o resultado ao arquivo de log.
  if [[ $commit_enabled == true ]]; then
    echo "$dateTime, $result" >> "logs/${key}_report.log"
    # Mantém apenas as últimas 2000 entradas de log.
    echo "$(tail -2000 "logs/${key}_report.log")" > "logs/${key}_report.log"
  else
    # Se commit estiver desabilitado, imprime o resultado no console.
    echo "    $dateTime, $result"
  fi
}

# Inicializa arrays para armazenar as chaves e URLs da configuração.
KEYSARRAY=()
URLSARRAY=()

# Especifica o arquivo de configuração contendo as URLs a serem checadas.
urlsConfig="./urls.cfg"
echo "Lendo $urlsConfig"
# Lê cada linha do arquivo de configuração.
while read -r line; do
  echo "  $line"
  # Divide cada linha em chave e URL com base no delimitador '='.
  IFS='=' read -ra TOKENS <<< "$line"
  # Adiciona a chave e a URL aos arrays respectivos.
  KEYSARRAY+=(${TOKENS[0]})
  URLSARRAY+=(${TOKENS[1]})
done < "$urlsConfig"

# Cria um diretório temporário para arquivos de status.
status_dir=$(mktemp -d)
# Garante que o diretório temporário seja limpo ao sair do script.
trap 'rm -rf -- "$status_dir"' EXIT

echo "***********************"
echo "Iniciando health checks em paralelo para ${#KEYSARRAY[@]} configs:"
echo  "node1-id: $NODE1_INSTANCE_ID"
echo  "node2-id: $NODE2_INSTANCE_ID"
echo "***********************"

# Cria o diretório de logs se ainda não existir.
mkdir -p logs

# Inicia todos os checks em background.
for (( index=0; index < ${#KEYSARRAY[@]}; index++ )); do
  check_url "${KEYSARRAY[index]}" "${URLSARRAY[index]}" "$commit" "$status_dir" &
done

# Aguarda todos os jobs em background terminarem.
wait
echo "Aguardando todos os checks terminarem..."
wait
echo "Todos os checks finalizados."

# Conta falhas verificando os arquivos de status.
# 'grep -l' lista arquivos contendo "failed", 'wc -l' os conta.
failed_checks=$(grep -l "failed" "$status_dir"/*.status 2>/dev/null | wc -l)

# Cria ou sobrescreve um arquivo temporário para indicar o status geral do health check.
if [[ $failed_checks -gt 0 ]]; then
  echo "failed" > check_status.tmp
  # Dispara evento para reiniciar instâncias se houver falha.
  echo "Alguns checks falharam. Reiniciando instâncias OCI."
  # Verifica se NODE1_INSTANCE_ID está definido e dispara o restart.
  # O NODE1_INSTANCE_ID deve estar definido como variável de ambiente (ex: no .env).
  if [ -n "$NODE1_INSTANCE_ID" ]; then
    echo "Tentando SOFTRESET na instância OCI NODE1: $NODE1_INSTANCE_ID"
    # O OCI CLI usará automaticamente as credenciais das variáveis de ambiente.
    oci compute instance action --action SOFTRESET --instance-id "$NODE1_INSTANCE_ID"
    if [ $? -eq 0 ]; then
      echo "Comando de restart da instância NODE1 emitido com sucesso."
    else
      # Saída para stderr para maior visibilidade nos logs
      echo "ERRO: Falha ao emitir comando de restart para NODE1." >&2
      exit 1 # Falha o build se o comando OCI falhar.
    fi
  else
    echo "AVISO: Variável de ambiente NODE1_INSTANCE_ID não definida. Pulando restart da instância."
  fi

  if [ -n "$NODE2_INSTANCE_ID" ]; then
    echo "Tentando SOFTRESET na instância OCI NODE2: $NODE2_INSTANCE_ID"
    oci compute instance action --action SOFTRESET --instance-id "$NODE2_INSTANCE_ID"
    if [ $? -eq 0 ]; then
      echo "Comando de restart da instância NODE2 emitido com sucesso."
    else
      echo "ERRO: Falha ao emitir comando de restart para NODE2." >&2
      exit 1
    fi
  fi
  # Garante que o job do GitHub Actions seja marcado como "Failed" se houver falhas.
  exit 1
else
  echo "success" > check_status.tmp
fi

# Se commit estiver habilitado, configura o Git, commita as mudanças de log e faz push para o repositório.
if [[ $commit == true ]]; then
  # Configura o Git com nome e email genéricos.
  git config --global user.name 'Unix-User'
  git config --global user.email 'wevertonslima@gmail.com'

  # Faz pull das últimas mudanças do remoto para evitar rejeições no push.
  # Usa --rebase para manter histórico linear.
  # Assume que o branch principal é 'main'.
  echo "Puxando últimas mudanças do origin main..."
  git pull --rebase origin main

  # Adiciona todas as mudanças no diretório de logs para o staging.
  git add -A --force logs/
  # Comita e faz push apenas se houver mudanças.
  if ! git diff --staged --quiet; then
    echo "Commitando e enviando atualizações dos logs..."
    git commit -m '[Automated] Update Health Check Logs'
    git push
  else
    echo "Nenhuma alteração de log para commitar."
  fi
fi
