**Desafio do Deploy em 1-Clique**

**Cenário do Trabalho:**
Você foi contratado por uma startup que precisa subir novos sites rapidamente no Ubuntu Server. A equipe de desenvolvimento entrega apenas um arquivo `.zip` com o código do site. A sua missão é criar um script em Bash (`deploy.sh`) que recebe esse arquivo e automatiza todo o processo de infraestrutura sem intervenção humana.

---

**O que o script deve fazer sozinho:**

**1. Receber parâmetros:**

* O script deve aceitar os seguintes argumentos de entrada:
```bash
./deploy.sh --site meu_site.zip --dominio empresa.local --porta 8080 --engine nginx

```


* Os parâmetros (`--site`, `--dominio`, `--porta` e `--engine`) devem ser validados.
* Os argumentos não necessitam validação, o usuário deverá fornecer corretamente.
* O parâmetro `engine` poderá ter como argumento `nginx` ou `apache2`.
* Caso falte um desses argumentos deverá ser informado ao usuário e o processamento cancelado.

**2. Processamento do Arquivo:**

* Descompactar o arquivo `.zip` no diretório do utilizador (`/home/usuario/public_html/site_nome`).
* Aplicar automaticamente as permissões de segurança corretas (`chmod` e `chown`) para o utilizador do Apache/Nginx (`www-data`).

**3. Configuração do Servidor Web (Apache ou Nginx):**

* Gerar dinamicamente o arquivo de configuração (`.conf` ou *Server Block*) apontando para a pasta descompactada e para a porta informada.
* Criar os links simbólicos necessários (`a2ensite` no Apache ou `ln -s` no Nginx).

**4. Segurança Automatizada:**

* Chamar o `openssl` via script para criar o certificado SSL autoassinado para o domínio informado sem parar para fazer perguntas interativas.
* Habilitar o HTTPS e o redirecionamento automático de HTTP para HTTPS.

**5. Validação:**

* Testar a sintaxe do servidor (`apache2ctl configtest` ou `nginx -t`).
* Recarregar o serviço (`systemctl reload`) e exibir uma mensagem no terminal:
```text
Sucesso! O seu site está no ar em: https://empresa.local:8080

```



---

* **Arquivo .zip de exemplo:** `trabalho.ds3.local.zip`
* **IMPORTANTE:** Usar apenas comandos vistos nos slides.

