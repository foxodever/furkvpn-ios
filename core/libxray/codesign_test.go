package libxray

import (
	"encoding/binary"
	"strings"
	"testing"
)

func TestParseSuperBlob(t *testing.T) {
	be := binary.BigEndian
	// Code directory 0x20400: identifier at 88, team after it.
	cd := make([]byte, 88)
	be.PutUint32(cd, 0xfade0c02)
	be.PutUint32(cd[8:], 0x20400)
	be.PutUint32(cd[20:], 88)
	cd = append(cd, "com.furkvpn.app.tunnel\x00ABCDE12345\x00"...)
	be.PutUint32(cd[48:], 88+uint32(len("com.furkvpn.app.tunnel\x00")))
	be.PutUint32(cd[4:], uint32(len(cd)))
	xml := `<plist><dict><key>application-identifier</key><string>ABCDE12345.*</string></dict></plist>`
	ent := append(make([]byte, 8), xml...)
	be.PutUint32(ent, 0xfade7171)
	be.PutUint32(ent[4:], uint32(len(ent)))
	blob := make([]byte, 12+16)
	be.PutUint32(blob, 0xfade0cc0)
	be.PutUint32(blob[8:], 2)
	be.PutUint32(blob[12:], 0)
	be.PutUint32(blob[16:], uint32(len(blob)))
	be.PutUint32(blob[20:], 5)
	be.PutUint32(blob[24:], uint32(len(blob)+len(cd)))
	blob = append(append(blob, cd...), ent...)
	be.PutUint32(blob[4:], uint32(len(blob)))

	info, err := parseSuperBlob(blob)
	if err != nil || info.Identifier != "com.furkvpn.app.tunnel" || info.Team != "ABCDE12345" || !strings.Contains(info.Entitlements, "ABCDE12345.*") {
		t.Errorf("info = %+v, %v", info, err)
	}
	if _, err := parseSuperBlob([]byte("not a signature")); err == nil {
		t.Error("garbage parsed")
	}
	if !strings.Contains(SignatureInfo("/no/such/file"), `"error"`) {
		t.Error("a missing file gave no error")
	}
}
