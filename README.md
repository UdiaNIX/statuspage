# Status Page Automatizado com Reinício de Instâncias OCI

Este projeto é uma versão modificada e estendida do [statuspage da Statsig](https://github.com/statsig-io/statuspage). Enquanto a base de monitoramento de URLs via GitHub Actions foi mantida, esta versão introduz funcionalidades significativas, principalmente a capacidade de interagir com a Oracle Cloud Infrastructure (OCI).

## Funcionalidades Principais

- **Monitoramento Contínuo**: Executa health checks em uma lista de URLs a cada 30 minutos usando GitHub Actions.
- **Página de Status Estática**: Gera uma página de status simples e limpa, hospedada gratuitamente via GitHub Pages.
- **Histórico de Uptime**: Mantém um registro dos resultados dos health checks, permitindo visualizar a estabilidade dos serviços ao longo do tempo.
- **✨ Nova Funcionalidade: Reinício Automático de Instâncias OCI**: Se um ou mais health checks falharem, o sistema tentará reiniciar automaticamente até duas instâncias pré-configuradas na Oracle Cloud Infrastructure (OCI) para tentar restaurar os serviços.

---

## Configuração

Siga os passos abaixo para configurar seu próprio monitor de status.

### Passo 1: Fork do Repositório

Comece fazendo um "fork" deste repositório para a sua conta do GitHub.

### Passo 2: Configurar as URLs para Monitoramento

Edite o arquivo `urls.cfg` na raiz do projeto. Adicione os serviços que você deseja monitorar, um por linha, no seguinte formato:

```
NOME_DO_SERVICO=https://seu.servico.com
OUTRO_SERVICO=https://outro.servico.com
```

### Passo 3: Configurar o Reinício de Instâncias OCI (Opcional)

Esta é a principal funcionalidade adicionada. Se você não utiliza OCI ou não deseja usar o reinício automático, pode pular esta etapa.

1.  **Crie um Ambiente no GitHub**:
    - No seu repositório, vá para `Settings` > `Environments` e clique em `New environment`.
    - Dê um nome ao ambiente (ex: `github-pages`, que é o padrão configurado no workflow) e clique em `Configure environment`.

2.  **Adicione os Secrets da OCI**:
    - Dentro da página de configuração do seu ambiente, na seção `Environment secrets`, adicione os seguintes secrets. Eles são necessários para que o GitHub Actions possa se autenticar na sua conta OCI.

      | Secret                | Descrição                                                                                             |
      | --------------------- | ----------------------------------------------------------------------------------------------------- |
      | `OCI_CLI_USER`        | O OCID do usuário da API na OCI.                                                                      |
      | `OCI_FINGERPRINT`     | O fingerprint da chave de API pública carregada na OCI.                                               |
      | `OCI_CLI_TENANCY`     | O OCID da sua tenancy na OCI.                                                                         |
      | `OCI_CLI_REGION`      | O identificador da sua região na OCI (ex: `sa-saopaulo-1`).                                           |
      | `OCI_KEY_FILE`        | O conteúdo completo da sua chave de API privada (o arquivo `.pem`).                                   |
      | `NODE1_INSTANCE_ID`   | O OCID da primeira instância que você deseja que seja reiniciada em caso de falha.                    |
      | `NODE2_INSTANCE_ID`   | O OCID da segunda instância (opcional).                                                               |

3.  **Configure as Permissões na OCI**:
    - Certifique-se de que o usuário da API na OCI tenha as permissões necessárias para gerenciar instâncias. Você precisará de uma política IAM parecida com esta:
      ```
      Allow group NOME_DO_GRUPO_DA_API to manage instance-family in tenancy
      ```

### Passo 4: Ativar o GitHub Pages

1.  No seu repositório, vá para `Settings` > `Pages`.
2.  Na seção `Build and deployment`, em `Source`, selecione `GitHub Actions`.
3.  O workflow já está configurado para construir e implantar a página automaticamente.

## Como Funciona

O workflow do GitHub Actions, definido em `.github/workflows/health-check.yml`, é o coração deste projeto.

- **Agendamento**: Ele é executado a cada 30 minutos.
- **Health Checks**: O script `health-check.sh` é executado, fazendo requisições HTTP para cada URL em `urls.cfg`.
- **Reinício OCI**: Se qualquer URL falhar, o script tentará executar um `SOFTRESET` nas instâncias OCI definidas nos secrets. A falha ou sucesso desta etapa será registrada como um `AVISO` nos logs.
- **Commit dos Logs**: O script commita os resultados dos checks no diretório `logs/`, mantendo o histórico.
- **Deploy**: O workflow do GitHub Pages (se configurado) pega os dados e atualiza a página de status.

## Agradecimentos

Este projeto não seria possível sem o trabalho inicial feito pela equipe da Statsig no repositório statsig-io/statuspage.

---