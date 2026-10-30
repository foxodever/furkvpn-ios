package libxray

import (
	"reflect"
	"testing"
)

func TestWhatPeopleTypeBecomesARule(t *testing.T) {
	cases := map[string]string{
		"youtube.com":                   "domain:youtube.com",
		"https://youtube.com/watch?v=1": "domain:youtube.com",
		"*.site.ru":                     "domain:.site.ru",
		"site.ru:443":                   "domain:site.ru",
		"кремль.рф":                     "domain:xn--e1ajeds9e.xn--p1ai",
		"1.2.3.4":                       "1.2.3.4",
		"10.0.0.0/8":                    "10.0.0.0/8",
		"2001:DB8::/32":                 "2001:db8::/32",
		"keyword:TikTok":                "keyword:tiktok",
		"full:api.example.com":          "full:api.example.com",
		// The leading dot is kept for the list.
		".com":        "domain:.com",
		".рф":         "domain:.xn--p1ai",
		"domain:.com": "domain:.com",
		// Keywords and Clash rules; our own "domain:" prefix is not Clash's DOMAIN (exact match).
		"KEYWORD:yandex":                "keyword:yandex",
		"DOMAIN-KEYWORD,yandex":         "keyword:yandex",
		"domain-keyword:Yandex":         "keyword:yandex",
		"DOMAIN-SUFFIX,ya.ru,DIRECT":    "domain:ya.ru",
		"DOMAIN,api.example.com":        "full:api.example.com",
		"IP-CIDR,1.2.3.0/24,no-resolve": "1.2.3.0/24",
		"domain:example.com":            "domain:example.com",
		"http://1.2.3.4/page":           "1.2.3.4",
		"IP-CIDR,300.1.1.0/24":          "",
		"geosite:google":                "", // no geo databases in the app
		"300.1.1.1/8":                   "",
		"300.1.1.1":                     "",
		"1.2.3.4/33":                    "",
		"not a domain!":                 "",
		"regexp:(":                      "",
	}
	for in, want := range cases {
		if got := normalizeRoute(in); got != want {
			t.Errorf("normalizeRoute(%q) = %q, want %q", in, got, want)
		}
	}
	if isIPOrCIDR("1:2:3") || !isIPOrCIDR("::ffff:1.2.3.4") {
		t.Error("isIPOrCIDR")
	}
}

func TestRouteDisplayAndXray(t *testing.T) {
	cases := []struct {
		fn       func(string) string
		in, want string
	}{
		{RouteDisplay, "domain:xn--e1ajeds9e.xn--p1ai", "кремль.рф"},
		{RouteDisplay, "domain:.com", ".com"},
		{RouteDisplay, "domain:.xn--p1ai", ".рф"},
		{RouteDisplay, "keyword:yandex", "yandex"},
		{RouteEditable, "keyword:yandex", "keyword:yandex"},
		{RouteEditable, "domain:.com", ".com"},
		{routeToXray, "domain:.com", "domain:com"},
		{routeToXray, "domain:youtube.com", "domain:youtube.com"},
	}
	for _, c := range cases {
		if got := c.fn(c.in); got != c.want {
			t.Errorf("%q -> %q, want %q", c.in, got, c.want)
		}
	}
}

func TestParseRouteList(t *testing.T) {
	check := func(text string, valid, invalid []string) {
		t.Helper()
		v, i := parseRouteList(text)
		if !reflect.DeepEqual(v, valid) || !reflect.DeepEqual(i, invalid) {
			t.Errorf("parseRouteList(%q) = %v, %v", text, v, i)
		}
	}
	check("DOMAIN-KEYWORD,yandex\nDOMAIN-SUFFIX,vk.com,DIRECT\nkeyword:ozon, .su",
		[]string{"keyword:yandex", "domain:vk.com", "keyword:ozon", "domain:.su"}, []string{})
	check("youtube.com, 1.1.1.1\r\n bad_host!, x.org",
		[]string{"domain:youtube.com", "1.1.1.1", "domain:x.org"}, []string{"bad_host!"})
	if got := ParseRouteList("ya.ru ya.ru"); got != `{"valid":["domain:ya.ru"],"invalid":[]}` {
		t.Errorf("ParseRouteList = %s", got)
	}
}
