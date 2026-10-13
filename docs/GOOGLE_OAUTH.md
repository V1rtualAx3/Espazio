# Configurer Google (Gmail, Google Chat, Google Agenda)

Espazio n’embarque **aucune clé** : chaque utilisateur (ou organisation) crée son propre client OAuth.
Tout se passe sur ce Mac ; aucun serveur Espazio n’existe.

## 1. Projet Google Cloud

1. <https://console.cloud.google.com/> → créer un projet (ex. « Espazio »).
2. *APIs & Services › Library* : activer selon vos besoins
   * **Gmail API**
   * **Google Chat API** (comptes Google Workspace uniquement, voir plus bas)
   * **Google Calendar API** (seulement si votre agenda Google n’est *pas* déjà synchronisé dans l’app
     Calendrier de macOS — sinon Espazio le lit via EventKit, sans doublon)

## 2. Écran de consentement

*APIs & Services › OAuth consent screen* (ou *Google Auth Platform › Branding / Audience*) :

* Type d’utilisateur : **Interne** (Workspace) ou **Externe** (compte personnel).
* En mode Externe « Testing », ajoutez votre adresse dans *Test users*. Les jetons de refresh des apps en
  mode test expirent au bout de 7 jours : passez l’app en production (sans vérification pour un usage
  personnel, Google affichera un avertissement « app non vérifiée ») ou reconnectez-vous chaque semaine.
* Champs d’application (scopes) utilisés — demandés progressivement :

| Scope | Quand |
|---|---|
| `gmail.readonly` | connexion Gmail |
| `gmail.modify` | au premier « Marquer comme lu » / « Archiver » |
| `chat.spaces.readonly`, `chat.messages.readonly`, `chat.messages.create` | connexion Google Chat |
| `calendar.events.readonly` | option « Google Agenda direct » |

## 3. Client OAuth

*Credentials › Create credentials › OAuth client ID* → type **Desktop app**.
Notez le **Client ID** et le **Client secret** (pour une application de bureau, Google indique que ce
secret n’est pas confidentiel ; Espazio le garde quand même dans le Trousseau).

## 4. Dans Espazio

Réglages › **Google** :

1. Collez le Client ID et le Client secret → **Enregistrer**.
2. Activez Gmail / Google Chat / Google Agenda.
3. **Connecter** : votre navigateur s’ouvre sur la page Google ; après accord, il est redirigé vers
   `http://127.0.0.1:<port>` (écouteur local temporaire d’Espazio, fermé immédiatement après).

Déconnecter : « Déconnecter et révoquer » révoque l’accès chez Google et efface le Trousseau.

## Google Chat : limites

L’API Google Chat avec authentification utilisateur n’est disponible que pour les comptes **Google
Workspace**, et le projet Cloud doit avoir une **application Chat configurée** (*Google Chat API ›
Configuration* : nom, avatar, description ; les fonctionnalités interactives peuvent rester désactivées).
Sur un compte personnel ou si un administrateur bloque l’accès, Espazio affiche « Non pris en charge pour
ce compte » sans affecter Gmail.

Les noms d’expéditeurs peuvent apparaître comme « Participant » : l’API ne renvoie pas toujours le nom
affiché en authentification utilisateur.

## Quotas et synchronisation

Intervalle réglable (1 à 30 min dans l’interface, 3 min par défaut). En cas de quota (`429`,
`rateLimitExceeded`) ou d’erreur serveur, Espazio applique un backoff exponentiel (30 s → 30 min) et
respecte `Retry-After`. La synchronisation est suspendue pendant la veille.
