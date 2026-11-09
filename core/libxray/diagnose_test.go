package libxray

import "testing"

func TestServerEndpoints(t *testing.T) {
	cfg := mustParse(t, `{"outbounds":[
	  {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"de.example.net","port":443}]}},
	  {"tag":"hy","protocol":"hysteria","settings":{"address":"1.2.3.4","port":8443}},
	  {"tag":"direct","protocol":"freedom"}]}`)
	got := serverEndpoints(cfg)
	if len(got) != 2 || got[0] != (serverEndpoint{"proxy", "de.example.net", 443, false}) || got[1] != (serverEndpoint{"hy", "1.2.3.4", 8443, true}) {
		t.Errorf("endpoints = %+v", got)
	}
	if DiagnoseRunning("https://example.com", "") != "ядро не запущено" {
		t.Error("diagnosed without a core")
	}
}
