package proto

// The hand-off card (docs/extensions/secret-providers.md "Who may approve a hand-off"): the card the manager shows
// before it hands secret values to one Agent run (secret.stage). Only the manager's own Agent start makes one; the hub
// lets only a device that may approve it say yes to it.

// SecretHandoffTool is the hand-off card's tool name, reserved as SecretRunTool is: a card from a node, a runtime or an
// extension that names it is refused.
const SecretHandoffTool = "secret_handoff"

// CodeSecretHandoffElsewhere is the hub's 403 to an approval of a hand-off card from a device or client that may not
// give one (an answer-only device, an extension's token, the hub's own token, an app that does not show the card):
// it is approved on the iPhone or the web.
const CodeSecretHandoffElsewhere = "secret_handoff_elsewhere"

// SecretHandoffInput is the hand-off card's ToolInput: the variables it hands over, each by the provider and the
// reference it comes from, never a value. The hub reads the providers only, to record a refused approval on each.
type SecretHandoffInput struct {
	Variables []SecretHandoffVariable `json:"variables"`
}

// SecretHandoffVariable is one environment variable a hand-off card hands over.
type SecretHandoffVariable struct {
	Name      string `json:"name"`
	Provider  string `json:"provider"`
	Reference string `json:"reference"`
}

// SecretHandoffDeclines reports whether r only says no to a hand-off card: deny, dismiss or cancel, with nothing that
// could read as yes. The hub and the manager take everything else as an approval, which only a device that may
// approve gives.
func SecretHandoffDeclines(r Resolution) bool {
	no := r.Allow != nil && !*r.Allow || r.Dismiss || r.Cancel
	yes := r.Allow != nil && *r.Allow || r.Approve != nil && *r.Approve || r.Always || r.Option != "" || len(r.Options) > 0 ||
		len(r.Keys) > 0 || len(r.PreKeys) > 0 || r.Text != "" || len(r.Answers) > 0 || len(r.Values) > 0 ||
		len(r.Content) > 0 || r.Action != "" || r.Mode != "" || r.Remembered
	return no && !yes
}
