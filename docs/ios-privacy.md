# Fritz for iPhone privacy policy

Fritz for iPhone stores chats, drafts, model selections, and provider settings
in the app's storage on your device. Fritz excludes this workspace from device
backups. Provider API keys are stored separately in the iPhone Keychain and
are available to Fritz on that device when it is unlocked.

Fritz asks for permission when you set up a provider. When you send a message
or retry a reply, Fritz sends the conversation history, the model ID, and any
API key required by the selected provider directly to that provider over HTTPS.
Loading the model catalog sends the provider your API key if one is configured.
For OpenRouter and other gateways, the gateway may route your request to one of
its upstream model providers. Each provider's own policies govern how it
handles requests and responses.

The app contains no analytics or advertising and sends no chat data to Fritz's
maintainers. Apple may receive TestFlight feedback or crash reports according
to your Apple settings and actions.

You can delete a chat from the Chats list and remove a saved connection and
its key from Providers. Device-side deletion does not erase records already
stored by your model provider.

For support, contact the [Fritz maintainers](https://github.com/rel-me/fritz).
