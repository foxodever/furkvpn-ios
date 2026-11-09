package libxray

import "testing"

func TestCodeFromTheTvLink(t *testing.T) {
	cases := map[string]string{
		"https://furkapp.net/tv/ABC234":        "ABC234",
		" https://furkapp.net/tv/abc-234/ ":    "ABC234",
		"furkvpn://tv/abc234":                  "ABC234",
		"https://furkapp.net/tv/":              "",
		"https://furkapp.net/tv/ABC2345":       "",
		"https://evil.net/tv/ABC234":           "",
		"https://sub.furkvpn.com/abcDEF123456": "",
		"":                                     "",
	}
	for in, want := range cases {
		if got := TvCodeFromLink(in); got != want {
			t.Errorf("TvCodeFromLink(%q) = %q, want %q", in, got, want)
		}
	}
}
