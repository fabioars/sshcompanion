import { Action, ActionPanel, Icon, LaunchProps, List, open, showToast, Toast } from "@raycast/api";
import { readFile } from "fs/promises";
import { homedir } from "os";
import { join } from "path";
import { useEffect, useState } from "react";

type Server = {
  id: string;
  name: string;
  path: string;
  host: string;
  port: number;
  username: string;
};

// Escrito pelo app sempre que a árvore de servidores muda. Não contém credenciais.
const INDEX_PATH = join(homedir(), "Library", "Application Support", "SSHCompanion", "servers.json");

async function loadServers(): Promise<Server[]> {
  const raw = await readFile(INDEX_PATH, "utf8");
  return JSON.parse(raw) as Server[];
}

function connectURL(server: Server): string {
  return `sshcompanion://connect?id=${encodeURIComponent(server.id)}`;
}

export default function Command(props: LaunchProps<{ arguments: { query?: string } }>) {
  const [servers, setServers] = useState<Server[]>([]);
  const [isLoading, setLoading] = useState(true);
  const [searchText, setSearchText] = useState(props.arguments.query ?? "");

  useEffect(() => {
    loadServers()
      .then(setServers)
      .catch(() =>
        showToast({
          style: Toast.Style.Failure,
          title: "Índice de servidores não encontrado",
          message: "Abra o SSH Companion uma vez para gerar o índice.",
        }),
      )
      .finally(() => setLoading(false));
  }, []);

  // Com um argumento que casa com exatamente um servidor, conecta direto sem mostrar a lista.
  useEffect(() => {
    const query = props.arguments.query?.trim().toLowerCase();
    if (!query || servers.length === 0) return;
    const matches = servers.filter((s) => s.name.toLowerCase().includes(query));
    if (matches.length === 1) {
      open(connectURL(matches[0]));
    }
  }, [servers]);

  return (
    <List
      isLoading={isLoading}
      searchText={searchText}
      onSearchTextChange={setSearchText}
      searchBarPlaceholder="Buscar servidor…"
      filtering={{ keepSectionOrder: true }}
    >
      <List.EmptyView
        icon={Icon.Terminal}
        title={isLoading ? "Carregando…" : "Nenhum servidor"}
        description="Cadastre servidores no SSH Companion para vê-los aqui."
      />
      {servers.map((server) => (
        <List.Item
          key={server.id}
          icon={Icon.Terminal}
          title={server.name}
          subtitle={`${server.username}@${server.host}${server.port !== 22 ? `:${server.port}` : ""}`}
          accessories={[{ text: server.path }]}
          keywords={[server.host, server.username, ...server.path.split(" / ")]}
          actions={
            <ActionPanel>
              <Action.Open title="Conectar no SSH Companion" target={connectURL(server)} icon={Icon.Terminal} />
              <Action.CopyToClipboard
                title="Copiar Comando SSH"
                content={`ssh -p ${server.port} ${server.username}@${server.host}`}
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
