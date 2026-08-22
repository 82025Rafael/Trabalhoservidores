## 1. Plano passo-a-passo para o desenvolvimento

**Etapa 1 — Estrutura e parsing de argumentos**
Criar o esqueleto do script com um laço `while` + `case` para ler `--site`, `--dominio`, `--porta` e `--engine` (equivalente ao padrão de flags usado no enunciado). Guardar cada valor em uma variável.

**Etapa 2 — Validação dos parâmetros**
Checar se as 4 variáveis foram preenchidas. Se faltar alguma, exibir mensagem de erro e `exit 1`. Validar que `--engine` seja exatamente `nginx` ou `apache2` — qualquer outro valor cancela o script.

**Etapa 3 — Processamento do arquivo .zip**
Definir o nome do site (ex.: a partir do domínio) e o caminho `/home/$USER/public_html/<site>`. Criar o diretório com `mkdir -p`, descompactar o zip dentro dele e aplicar `chown -R www-data` + `chmod -R 755`.

**Etapa 4 — Geração da configuração do servidor**
Usar uma condicional (`if [ "$ENGINE" = "nginx" ]`) para gerar dinamicamente:
- Nginx: um *server block* com `listen`, `server_name`, `root`, `index`, `location /`.
- Apache: um *VirtualHost* com `ServerName`, `DocumentRoot`, `<Directory>`.

**Etapa 5 — Ativação do site**
Nginx: `ln -s` de `sites-available` para `sites-enabled`.
Apache: `a2ensite`.

**Etapa 6 — Certificado SSL automatizado**
Chamar `openssl req -x509 -nodes -days 365 -newkey rsa:2048` apontando `-keyout`/`-out`, usando `-subj "/CN=$DOMINIO"` para evitar as perguntas interativas do modo padrão.

**Etapa 7 — Bloco HTTPS + redirecionamento**
Adicionar ao mesmo arquivo (ou a um segundo bloco `:443`) as diretivas `SSLEngine`/`SSLCertificateFile` (Apache) ou `listen 443 ssl` (Nginx), e um redirect 301 da porta informada para a porta HTTPS.

**Etapa 8 — Validação de sintaxe**
Rodar `apache2ctl configtest` ou `nginx -t` conforme o engine escolhido.

**Etapa 9 — Reload do serviço**
`systemctl reload apache2` ou `systemctl reload nginx`.

**Etapa 10 — Mensagem final**
Exibir `Sucesso! O seu site está no ar em: https://<dominio>:<porta>`.

**Etapa 11 — Testes**
Rodar o script duas vezes (uma para cada engine) com o `trabalho.ds3.local.zip` de exemplo e conferir no navegador/`curl -k`.

> **Observação:** o `.zip` precisa ser descompactado com `unzip`, comando que não aparece nos slides de Apache/Nginx — é uma dependência inevitável para cumprir o requisito 2 do enunciado; vale confirmar com o professor se pode ser usado.

---

Agora o rascunho do script:Alguns pontos que valem revisão antes de entregar como trabalho final:

- **`unzip`** não aparece nos slides, mas é indispensável para descompactar o `.zip` — vale confirmar com o professor se é aceitável ou se deve ser trocado por outra abordagem.
- O redirecionamento HTTP→HTTPS no bloco Nginx assume que a porta informada (`--porta`) é a porta "pública" tanto para o site HTTP quanto para o redirecionamento — pode ser ajustado se a intenção for sempre usar 80 para HTTP e a porta customizada só para HTTPS.
- É um rascunho: não trata casos como zip corrompido, domínio já configurado, ou execução sem `sudo`/permissões.

