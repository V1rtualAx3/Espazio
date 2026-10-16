# Intégrations d’agents IA (Claude Code, Codex, ChatGPT)

## Claude Code — hooks documentés

Référence : <https://code.claude.com/docs/en/hooks> (vérifiée le 13/10/2026 ; voir réserves en fin de
document).

### Installation

Réglages › **Agents IA** › « Hooks Espazio installés ». Espazio modifie `~/.claude/settings.json` :

* une sauvegarde `settings.json.espazio-backup` est écrite avant toute modification ;
* seules les entrées dont la commande contient `espazio-hook` sont ajoutées/retirées, tous vos autres
  réglages et hooks sont conservés ;
* l’opération est idempotente ; décocher retire les hooks.

Hooks installés (`type: "command"`, commande = `…/Espazio.app/Contents/MacOS/espazio-hook`) :

| Événement | Délai | Usage |
|---|---|---|
| `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Notification`, `Stop` | 5 s | état des sessions (fire-and-forget, l’assistant rend la main en < 1,5 s) |
| `PermissionRequest` (matcher `*`) | 600 s | décision « Autoriser une fois » / « Refuser » depuis la notch |

Installation manuelle équivalente :

```json
{
  "hooks": {
    "PermissionRequest": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "'/Applications/Espazio.app/Contents/MacOS/espazio-hook'", "timeout": 600 } ] }
    ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "'/Applications/Espazio.app/Contents/MacOS/espazio-hook'", "timeout": 5 } ] } ]
  }
}
```

### Quelles sessions apparaissent ?

Uniquement les sessions Claude Code **exécutées sur ce Mac** (terminal, VS Code…) avec les hooks
installés dans le `~/.claude/settings.json` de ce Mac. Les sessions Claude Code sur le web / dans le cloud
(claude.ai/code) tournent sur une autre machine : elles ne peuvent pas joindre la socket locale d’Espazio
et n’apparaissent donc pas.

### Comportement

* Sortie de décision : `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
  ou `{"behavior":"deny","message":"…"}`. Jamais de `updatedPermissions` (aucune règle persistante).
* Délai Espazio (Réglages, 300 s par défaut, 15–600 s) dépassé → **refus**.
* Espazio fermé / bridge injoignable / réponse invalide → l’assistant n’écrit rien et sort avec le code 0 :
  Claude Code applique son comportement normal (sa propre demande dans le terminal). Ce n’est jamais une
  autorisation.
* `AskUserQuestion` et `ExitPlanMode` sont laissés à l’interface de Claude Code (la documentation indique
  qu’« allow » seul ne suffit pas pour ces outils).
* Bouton « Ouvrir le terminal » : active l’application identifiée par `__CFBundleIdentifier` ou
  `TERM_PROGRAM` (Terminal, iTerm2, VS Code, Warp, Ghostty, WezTerm, Zed…). L’onglet exact n’est pas
  ciblable sans API dédiée.

### Réserves (à revalider)

La documentation consultée ne précise pas explicitement le comportement d’un hook `PermissionRequest`
qui ne renvoie aucune décision (sortie 0 sans JSON) ; par analogie avec `PreToolUse`, la demande normale
de Claude Code s’affiche. À vérifier sur la version installée (checklist manuelle, test A3).

## Codex

### Sessions pilotées par Espazio — `codex app-server`

Référence : <https://developers.openai.com/codex/app-server/> et le code source `openai/codex`
(`codex-rs/app-server-protocol`), revus le 13/10/2026.

* Lancement à la demande (Agents IA › « Session Codex » ou Actions rapides) : choix d’un dossier, saisie de
  la tâche → `codex app-server` (stdio), `initialize` / `initialized`, `thread/start`
  (`approvalPolicy: "on-request"`), `turn/start`.
* Protocole : un objet JSON par ligne, messages de type JSON-RPC **sans** champ `jsonrpc`.
* Requêtes serveur traitées :

| Méthode | Réponse Espazio |
|---|---|
| `item/commandExecution/requestApproval` | `{"decision":"accept"}` uniquement après « Autoriser une fois » ; refus → `decline` ; délai → `decline` ; déconnexion/annulation → `cancel` |
| `item/fileChange/requestApproval` | idem (chemins issus de l’item `fileChange`) |
| `item/tool/requestUserInput` (expérimental) | première question affichée, réponse texte ou option ; refus → erreur JSON-RPC |
| `execCommandApproval`, `applyPatchApproval` (anciennes API) | `approved` / `denied` / `timed_out` / `abort` |
| toute autre requête | erreur `-32601` (le serveur n’attend jamais indéfiniment) |

* `acceptForSession` n’est jamais envoyé.
* Le processus est arrêté après 15 min sans activité ni demande en attente.
* Exécutable recherché dans `PATH` puis `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`,
  `~/.npm-global/bin`, `~/.volta/bin`, `~/.bun/bin`, `~/.cargo/bin` (le PATH enfant est complété pour que
  la distribution npm trouve `node`).

### Sessions Codex CLI indépendantes — `notify` (lecture seule)

Réglages › Agents IA › « Suivre les sessions Codex CLI » ajoute en tête de `~/.codex/config.toml` :

```toml
notify = ["/Applications/Espazio.app/Contents/MacOS/espazio-hook", "codex-notify"]
```

Codex exécute ce programme avec un JSON (`type: "agent-turn-complete"`, `thread-id`, `cwd`,
`last-assistant-message`) à la fin de chaque tour. Ces sessions sont affichées **« Lecture seule »** :
Espazio ne peut ni approuver ni répondre pour elles (aucun mécanisme officiel ne le permet). Si un
`notify` existe déjà, Espazio ne le remplace pas.

## ChatGPT Desktop — meilleur effort

Uniquement : application ouverte/fermée (`NSWorkspace`) et bouton d’ouverture. Aucun contrôle
d’autorisation n’est supposé possible : aucune API officielle ne l’expose.

## Bridge local

Voir [SECURITY.md](SECURITY.md#bridge-local). Pour un développement hors bundle, la variable
`ESPAZIO_BRIDGE_SOCKET` permet de choisir le chemin de la socket.
