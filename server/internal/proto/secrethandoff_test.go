package proto

import (
	"encoding/json"
	"testing"
)

// Only a plain no passes for a decline of a hand-off card: anything that could read as yes beside it makes the answer
// an approval, which only a device that may approve gives.
func TestSecretHandoffDeclines(t *testing.T) {
	for body, want := range map[string]bool{
		`{"allow":false}`:                       true,
		`{"dismiss":true}`:                      true,
		`{"cancel":true}`:                       true,
		`{"allow":false,"message":"not now"}`:   true,
		`{"allow":false,"feedback":"no"}`:       true,
		`{}`:                                    false,
		`{"allow":true}`:                        false,
		`{"allow":false,"always":true}`:         false,
		`{"dismiss":true,"allow":true}`:         false,
		`{"allow":false,"approve":true}`:        false,
		`{"dismiss":true,"option":"1"}`:         false,
		`{"dismiss":true,"options":["1"]}`:      false,
		`{"allow":false,"keys":["1"]}`:          false,
		`{"allow":false,"pre_keys":["1"]}`:      false,
		`{"allow":false,"text":"y"}`:            false,
		`{"cancel":true,"answers":{"q":"yes"}}`: false,
		`{"allow":false,"values":{"k":"v"}}`:    false,
		`{"allow":false,"content":{"k":"v"}}`:   false,
		`{"dismiss":true,"action":"accept"}`:    false,
		`{"allow":false,"mode":"default"}`:      false,
		`{"allow":false,"remembered":true}`:     false,
		`{"approve":false}`:                     false, // a plan card's no: not a hand-off card's answer
	} {
		var r Resolution
		if err := json.Unmarshal([]byte(body), &r); err != nil {
			t.Fatal(err)
		}
		if got := SecretHandoffDeclines(r); got != want {
			t.Errorf("%s: declines %v, want %v", body, got, want)
		}
	}
}
