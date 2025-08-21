#!/bin/bash
set -e # Garante que o script pare imediatamente se um comando falhar.

# Carrega variáveis de ambiente do arquivo .env, se existir
if [ -f .env ]; then
  echo "Carregando variáveis de ambiente do arquivo .env"
  set -o allexport
  source .env
  set +o allexport
fi

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

# Função para reiniciar uma única instância OCI.
restart_oci_instance() {
  local instance_id=$1
  local instance_name=$2

  if [ -n "$instance_id" ]; then
    echo "Tentando SOFTRESET na instância OCI ${instance_name}: ${instance_id}"
    if oci compute instance action --action SOFTRESET --instance-id "$instance_id"; then
      echo "AVISO: Comando de restart para a instância ${instance_name} foi emitido com sucesso."
    else
      echo "AVISO: Falha ao emitir comando de restart para ${instance_name}. O job continuará, mas a instância pode não ter sido reiniciada." >&2
      return 1 # Retorna um código de erro
    fi
  fi
}

# Cria ou sobrescreve um arquivo temporário para indicar o status geral do health check.
if [[ $failed_checks -gt 0 ]]; then
  echo "failed" > check_status.tmp
  # Dispara evento para reiniciar instâncias se houver falha.
  echo "Alguns checks falharam. Tentando reiniciar instâncias OCI."

  # Verifica se o comando 'oci' está disponível e se a autenticação foi configurada.
  if ! command -v oci &> /dev/null; then
    echo "ERRO: Comando 'oci' não encontrado no PATH. Pulando restart." >&2
  elif [ ! -f ~/.oci/config ]; then
    echo "AVISO: Arquivo de configuração OCI (~/.oci/config) não encontrado. Pulando restart."
  else
    restart_failed=0
    restart_oci_instance "$NODE1_INSTANCE_ID" "NODE1" || restart_failed=1
    restart_oci_instance "$NODE2_INSTANCE_ID" "NODE2" || restart_failed=1
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
