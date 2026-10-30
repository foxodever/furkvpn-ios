package libxray

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func subscriptionConfig(remarks string, balancer bool, addresses ...string) string {
	var outbounds []string
	for i, address := range addresses {
		tag := "proxy"
		if i > 0 {
			tag = fmt.Sprintf("proxy-%d", i)
		}
		outbounds = append(outbounds, fmt.Sprintf(`{"tag":%q,"protocol":"vless","settings":{"vnext":[{"address":%q,"port":443,"users":[{"id":"x"}]}]},
		  "streamSettings":{"network":"xhttp","security":"reality"}}`, tag, address))
	}
	outbounds = append(outbounds, `{"tag":"direct","protocol":"freedom"}`)
	routing := ""
	if balancer {
		routing = `,"routing":{"balancers":[{"tag":"b","selector":["proxy"]}]}`
	}
	return fmt.Sprintf(`{"remarks":%q,"outbounds":[%s]%s}`, remarks, strings.Join(outbounds, ","), routing)
}

func TestEntriesFromRemnawaveJSON(t *testing.T) {
	body := "[" + strings.Join([]string{
		subscriptionConfig("⬇️ Автовыбор ⬇️", false, "0.0.0.0"),
		subscriptionConfig("🇪🇺 Автовыбор Wi-Fi 🎲", true, "a.net", "b.net"),
		subscriptionConfig("⬇️ Внизу Домашние (Wi-Fi) ⬇️", false, "0.0.0.0"),
		subscriptionConfig("🇳🇱 Нидерланды ⚡", false, "nl.net"),
		subscriptionConfig("🇳🇱 Нидерланды ⚡", false, "nl2.net"),
		subscriptionConfig("Без флага", false, "x.net"),
	}, ",") + "]"
	sub, err := parseSubscription(body)
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, e := range sub.Servers {
		kinds = append(kinds, e.Kind)
	}
	if want := []string{"SEPARATOR", "AUTO", "SEPARATOR", "SERVER", "SERVER", "SERVER"}; !reflect.DeepEqual(kinds, want) {
		t.Errorf("kinds = %v", kinds)
	}
	e := sub.Servers
	check := func(got, want string) {
		t.Helper()
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	}
	check(e[0].Title, "Автовыбор")
	check(e[2].Title, "Домашние (Wi-Fi)")
	check(e[1].Flag, "🇪🇺")
	check(e[1].Title, "Автовыбор Wi-Fi 🎲")
	check(e[3].Summary, "VLESS · XHTTP · REALITY")
	// Duplicate names get distinct, stable keys.
	check(e[3].Key, "🇳🇱 Нидерланды ⚡#1")
	check(e[4].Key, "🇳🇱 Нидерланды ⚡#2")
	check(e[5].Flag, "")
	check(e[5].Title, "Без флага")
	if len(sub.Configs) != 6 || !strings.Contains(sub.Configs[4], `"nl2.net"`) || !strings.Contains(sub.Configs[4], `"port":443`) {
		t.Errorf("configs = %v", sub.Configs)
	}
}

func TestHysteriaServerEntry(t *testing.T) {
	// The shape Remnawave gives a Hysteria 2 host in the Xray JSON subscription.
	body := `[{"remarks":"🇩🇪 Германия Hysteria","outbounds":[
	    {"tag":"proxy","protocol":"hysteria","settings":{"address":"de.net","port":443,"version":2},
	     "streamSettings":{"network":"hysteria","hysteriaSettings":{"version":2,"auth":"x"},"security":"tls",
	       "tlsSettings":{"serverName":"de.net","alpn":["h3"]},
	       "finalmask":{"udp":[{"type":"salamander","settings":{"password":"y"}}]}}},
	    {"tag":"direct","protocol":"freedom"}]}]`
	out, err := ParseSubscription(body)
	if err != nil {
		t.Fatal(err)
	}
	var sub parsedSubscription
	if err := json.Unmarshal([]byte(out), &sub); err != nil {
		t.Fatal(err)
	}
	want := serverEntry{Key: "🇩🇪 Германия Hysteria#1", Remarks: "🇩🇪 Германия Hysteria", Flag: "🇩🇪", Title: "Германия Hysteria", Kind: "SERVER", Summary: "HYSTERIA2 · QUIC"}
	if len(sub.Servers) != 1 || sub.Servers[0] != want {
		t.Errorf("servers = %+v", sub.Servers)
	}
	// The config is kept as the panel sent it, numbers included.
	var cfg map[string]any
	if err := json.Unmarshal([]byte(sub.Configs[0]), &cfg); err != nil || !strings.Contains(sub.Configs[0], `"version":2`) {
		t.Errorf("config = %s (%v)", sub.Configs[0], err)
	}
}

func TestBadSubscriptions(t *testing.T) {
	for body, want := range map[string]string{
		"":                  "bad format",
		"<html>":            "bad format",
		`[{"remarks":"x"}]`: "bad format",
		`"text"`:            "bad format",
		"[" + subscriptionConfig("⬇️ Внизу ⬇️", false, "0.0.0.0") + "]": "no servers",
	} {
		if _, err := ParseSubscription(body); err == nil || err.Error() != want {
			t.Errorf("%q: %v, want %s", body, err, want)
		}
	}
	// A single config instead of an array is taken too.
	if out, err := ParseSubscription(subscriptionConfig("🇳🇱 Нидерланды", false, "nl.net")); err != nil || !strings.Contains(out, `"kind":"SERVER"`) {
		t.Errorf("single config: %s, %v", out, err)
	}
}

func TestHeaders(t *testing.T) {
	if got := DecodeHeader("base64:RnVya1ZQTiB8INCf0L7QtNC/0LjRgdC60LA="); got != "FurkVPN | Подписка" {
		t.Errorf("base64 = %q", got)
	}
	if got := DecodeHeader("plain"); got != "plain" {
		t.Errorf("plain = %q", got)
	}
	if got := DecodeHeader(""); got != "" {
		t.Errorf("empty = %q", got)
	}
	if got := ParseUserInfo("upload=1; download=2; total=0; expire=1790000000"); got != `{"download":2,"expire":1790000000,"total":0,"upload":1}` {
		t.Errorf("userinfo = %s", got)
	}
	if got := ParseUserInfo(""); got != `{}` {
		t.Errorf("empty userinfo = %s", got)
	}
}
