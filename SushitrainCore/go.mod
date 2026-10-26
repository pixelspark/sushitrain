module t-shaped.nl/sushitrain/v2

go 1.27.0

replace github.com/gobwas/glob v0.2.3 => github.com/calmh/glob v0.0.0-20220615080505-1d823af5017b

// gomobile includes tool dependencies in its generated module. Upgrade the legacy
// genproto pulled in by go-licenses so it does not overlap the split API modules.
replace google.golang.org/genproto v0.0.0-20220815135757-37a418bb8959 => google.golang.org/genproto v0.0.0-20230526161137-0005af68ea54

require (
	github.com/gobwas/glob v0.2.3
	github.com/gofrs/flock v0.13.1
	github.com/hashicorp/golang-lru/v2 v2.0.7
	github.com/hooklift/iso9660 v1.0.0
	github.com/miscreant/miscreant.go v0.0.0-20200214223636-26d376326b75
	github.com/syncthing/syncthing v1.30.0-rc.1.0.20261020195438-d6d0181f7d46
	golang.org/x/exp v0.0.0-20261007192929-f45ad48fbe92
	google.golang.org/protobuf v1.36.12
)

require (
	buf.build/gen/go/bufbuild/protovalidate/protocolbuffers/go v1.36.12-20260825204119-511051f7f437.2 // indirect
	buf.build/go/protovalidate v1.4.0 // indirect
	cel.dev/cel-go v0.32.0 // indirect
	cel.dev/expr v0.25.3 // indirect
	github.com/Azure/go-ntlmssp v0.1.1 // indirect
	github.com/antlr4-go/antlr/v4 v4.13.1 // indirect
	github.com/beorn7/perks v1.0.1 // indirect
	github.com/c4milo/gotoolkit v0.0.0-20190525173301-67483a18c17a // indirect
	github.com/calmh/incontainer v1.0.0 // indirect
	github.com/calmh/xdr v1.2.0 // indirect
	github.com/ccding/go-stun v0.1.6 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/dustin/go-humanize v1.0.1 // indirect
	github.com/ebitengine/purego v0.11.2 // indirect
	github.com/emirpasic/gods v1.12.0 // indirect
	github.com/go-asn1-ber/asn1-ber v1.5.8 // indirect
	github.com/go-ldap/ldap/v3 v3.4.15 // indirect
	github.com/go-logr/logr v1.4.2 // indirect
	github.com/go-ole/go-ole v1.3.0 // indirect
	github.com/golang/groupcache v0.0.0-20210331224755-41bb18bfe9da // indirect
	github.com/golang/snappy v1.0.0 // indirect
	github.com/google/go-licenses v1.6.0 // indirect
	github.com/google/licenseclassifier v0.0.0-20210722185704-3043a050f148 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/hooklift/assert v0.1.0 // indirect
	github.com/inconshreveable/mousetrap v1.0.1 // indirect
	github.com/jackpal/gateway v1.2.0 // indirect
	github.com/jackpal/go-nat-pmp v1.1.0 // indirect
	github.com/jbenet/go-context v0.0.0-20150711004518-d14ea06fba99 // indirect
	github.com/jmoiron/sqlx v1.4.0 // indirect
	github.com/julienschmidt/httprouter v1.3.0 // indirect
	github.com/kballard/go-shellquote v0.0.0-20180428030007-95032a82bc51 // indirect
	github.com/kevinburke/ssh_config v0.0.0-20190725054713-01f96b0aa0cd // indirect
	github.com/lufia/plan9stats v0.0.0-20260802145828-341c2f0c90b5 // indirect
	github.com/mattn/go-isatty v0.0.24 // indirect
	github.com/mattn/go-sqlite3 v1.14.52 // indirect
	github.com/mitchellh/go-homedir v1.1.0 // indirect
	github.com/munnerz/goautoneg v0.0.0-20191010083416-a7dc8b61c822 // indirect
	github.com/ncruces/go-strftime v1.0.0 // indirect
	github.com/onsi/gomega v1.37.0 // indirect
	github.com/otiai10/copy v1.6.0 // indirect
	github.com/pierrec/lz4/v4 v4.1.33 // indirect
	github.com/power-devops/perfstat v0.0.0-20260916203055-22a1a467d9f0 // indirect
	github.com/prometheus/client_golang v1.25.0 // indirect
	github.com/prometheus/client_model v0.6.3 // indirect
	github.com/prometheus/common v0.72.1 // indirect
	github.com/prometheus/procfs v0.23.0 // indirect
	github.com/quic-go/quic-go v0.63.0 // indirect
	github.com/rcrowley/go-metrics v0.0.0-20250401214520-65e299d6c5c9 // indirect
	github.com/remyoudompheng/bigfft v0.0.0-20230129092748-24d4a6f8daec // indirect
	github.com/sergi/go-diff v1.2.0 // indirect
	github.com/shirou/gopsutil/v4 v4.26.9 // indirect
	github.com/spf13/cobra v1.6.0 // indirect
	github.com/spf13/pflag v1.0.5 // indirect
	github.com/src-d/gcfg v1.4.0 // indirect
	github.com/syncthing/notify v0.0.0-20250528144937-c7027d4f7465 // indirect
	github.com/syndtr/goleveldb v1.0.1-0.20220721030215-126854af5e6d // indirect
	github.com/thejerf/suture/v4 v4.0.6 // indirect
	github.com/tklauser/go-sysconf v0.4.0 // indirect
	github.com/tklauser/numcpus v0.12.0 // indirect
	github.com/vitrun/qart v0.0.0-20160531060029-bf64b92db6b0 // indirect
	github.com/wlynxg/anet v0.0.5 // indirect
	github.com/xanzy/ssh-agent v0.2.1 // indirect
	github.com/yusufpapurcu/wmi v1.2.4 // indirect
	go.opencensus.io v0.24.0 // indirect
	go.yaml.in/yaml/v3 v3.0.5 // indirect
	golang.org/x/crypto v0.58.0 // indirect
	golang.org/x/mobile v0.0.0-20260410095206-2cfb76559b7b // indirect
	golang.org/x/mod v0.41.0 // indirect
	golang.org/x/net v0.61.0 // indirect
	golang.org/x/sync v0.24.0 // indirect
	golang.org/x/sys v0.49.0 // indirect
	golang.org/x/text v0.43.0 // indirect
	golang.org/x/time v0.16.0 // indirect
	golang.org/x/tools v0.51.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20260819154853-08b0e4226688 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260819154853-08b0e4226688 // indirect
	gopkg.in/src-d/go-billy.v4 v4.3.2 // indirect
	gopkg.in/src-d/go-git.v4 v4.13.1 // indirect
	gopkg.in/warnings.v0 v0.1.2 // indirect
	k8s.io/klog/v2 v2.80.1 // indirect
	modernc.org/libc v1.77.1 // indirect
	modernc.org/mathutil v1.7.1 // indirect
	modernc.org/memory v1.12.1 // indirect
	modernc.org/sqlite v1.60.1 // indirect
)

tool (
	github.com/google/go-licenses
	golang.org/x/mobile/cmd/gobind
	golang.org/x/mobile/cmd/gomobile
)
