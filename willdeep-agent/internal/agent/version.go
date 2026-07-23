package agent

import "runtime"

const Version = "1.194.0-rc14"

type VersionReport struct {
	Name      string `json:"name"`
	Version   string `json:"version"`
	GoVersion string `json:"go_version"`
	OS        string `json:"os"`
	Arch      string `json:"arch"`
}

func VersionInfo() VersionReport {
	return VersionReport{
		Name:      "willdeep-agent",
		Version:   Version,
		GoVersion: runtime.Version(),
		OS:        runtime.GOOS,
		Arch:      runtime.GOARCH,
	}
}
