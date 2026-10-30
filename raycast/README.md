# SSH Companion para Raycast

Comando `ssh`: lista os servidores cadastrados no SSH Companion e abre uma aba conectada.

Digite `ssh cabana` no Raycast: se um único servidor casar com o texto, conecta direto;
senão a lista aparece filtrada.

## Como funciona

- O app grava `~/Library/Application Support/SSHCompanion/servers.json` sempre que a árvore muda
  (sem credenciais).
- A extensão lê esse arquivo e, ao escolher um item, abre `sshcompanion://connect?id=<uuid>`.
- O app também aceita `sshcompanion://connect?server=<texto>` com busca por nome
  (exato, prefixo, trecho, subsequência), útil para Script Commands ou `open` no terminal.

## Instalar (desenvolvimento)

```sh
cd raycast
npm install
npm run dev
```

O Raycast importa a extensão em modo de desenvolvimento. Gere um `assets/icon.png` (512×512)
antes de publicar na Store.
