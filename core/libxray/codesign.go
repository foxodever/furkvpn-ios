package libxray

import (
	"bytes"
	"debug/macho"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"os"
)

// What re-signing tools leave in the app's and the VPN extension's code signatures: iOS matches the
// extension and the app that controls it by these, so the diagnostics screen shows them.

type signatureInfo struct {
	Identifier   string `json:"identifier,omitempty"`
	Team         string `json:"team,omitempty"`
	Entitlements string `json:"entitlements,omitempty"`
	Error        string `json:"error,omitempty"`
}

// SignatureInfo reads the code signature of a Mach-O executable: JSON {"identifier", "team",
// "entitlements" (the XML plist)} or {"error"}.
func SignatureInfo(path string) string {
	info, err := readSignature(path)
	if err != nil {
		info = signatureInfo{Error: err.Error()}
	}
	b, _ := json.Marshal(info)
	return string(b)
}

func readSignature(path string) (signatureInfo, error) {
	file, err := os.Open(path)
	if err != nil {
		return signatureInfo{}, err
	}
	defer file.Close()
	var base int64
	f, err := macho.NewFile(file)
	if err != nil {
		fat, fatErr := macho.NewFatFile(file)
		if fatErr != nil || len(fat.Arches) == 0 {
			return signatureInfo{}, err
		}
		f, base = fat.Arches[0].File, int64(fat.Arches[0].Offset)
	}
	for _, l := range f.Loads {
		raw := l.Raw()
		if len(raw) < 16 || f.ByteOrder.Uint32(raw) != 0x1d { // LC_CODE_SIGNATURE
			continue
		}
		offset, size := f.ByteOrder.Uint32(raw[8:]), f.ByteOrder.Uint32(raw[12:])
		blob := make([]byte, size)
		if _, err := file.ReadAt(blob, base+int64(offset)); err != nil && err != io.EOF {
			return signatureInfo{}, err
		}
		return parseSuperBlob(blob)
	}
	return signatureInfo{}, errors.New("не подписан")
}

// parseSuperBlob takes the identifier and team from the first code directory and the XML entitlements.
func parseSuperBlob(blob []byte) (signatureInfo, error) {
	be := binary.BigEndian
	if len(blob) < 12 || be.Uint32(blob) != 0xfade0cc0 {
		return signatureInfo{}, errors.New("неизвестный формат подписи")
	}
	var info signatureInfo
	count := int(be.Uint32(blob[8:]))
	for i := 0; i < count && 12+8*i+8 <= len(blob); i++ {
		slot, at := be.Uint32(blob[12+8*i:]), int(be.Uint32(blob[16+8*i:]))
		if at+8 > len(blob) {
			continue
		}
		magic, length := be.Uint32(blob[at:]), int(be.Uint32(blob[at+4:]))
		if length < 8 || at+length > len(blob) {
			continue
		}
		b := blob[at : at+length]
		switch {
		case slot == 0 && magic == 0xfade0c02 && len(b) >= 52: // the code directory
			info.Identifier = cString(b, int(be.Uint32(b[20:])))
			if be.Uint32(b[8:]) >= 0x20200 {
				info.Team = cString(b, int(be.Uint32(b[48:])))
			}
		case slot == 5 && magic == 0xfade7171: // entitlements, XML
			info.Entitlements = string(b[8:])
		}
	}
	return info, nil
}

func cString(b []byte, at int) string {
	if at <= 0 || at >= len(b) {
		return ""
	}
	if end := bytes.IndexByte(b[at:], 0); end >= 0 {
		return string(b[at : at+end])
	}
	return ""
}
