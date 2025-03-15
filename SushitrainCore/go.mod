module t-shaped.nl/sushitrain/v2

go 1.23.0

toolchain go1.24.0

replace github.com/syncthing/syncthing => /Users/tommy/Repos/syncthing

require (
	github.com/gotd/contrib v0.21.0
	github.com/miscreant/miscreant.go v0.0.0-20200214223636-26d376326b75
	github.com/syncthing/syncthing v1.29.3-rc.1.0.20250207154053-28f0cffdb6ad
)

require (
	github.com/Azure/go-ntlmssp v0.0.0-20221128193559-754e69321358 // indirect
	github.com/beorn7/perks v1.0.1 // indirect
	github.com/calmh/incontainer v1.0.0 // indirect
	github.com/calmh/xdr v1.2.0 // indirect
	github.com/ccding/go-stun v0.1.5 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/chmduquesne/rollinghash v4.0.0+incompatible // indirect
	github.com/davecgh/go-spew v1.1.1 // indirect
	github.com/dustin/go-humanize v1.0.1 // indirect
	github.com/go-asn1-ber/asn1-ber v1.5.7 // indirect
	github.com/go-ldap/ldap/v3 v3.4.10 // indirect
	github.com/go-ole/go-ole v1.3.0 // indirect
	github.com/go-task/slim-sprig/v3 v3.0.0 // indirect
	github.com/gobwas/glob v0.2.3 // indirect
	github.com/golang/snappy v0.0.4 // indirect
	github.com/google/pprof v0.0.0-20241210010833-40e02aabc2ad // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/greatroar/blobloom v0.8.0 // indirect
	github.com/hashicorp/golang-lru/v2 v2.0.7 // indirect
	github.com/jackpal/gateway v1.0.16 // indirect
	github.com/jackpal/go-nat-pmp v1.0.2 // indirect
	github.com/jmoiron/sqlx v1.4.0 // indirect
	github.com/julienschmidt/httprouter v1.3.0 // indirect
	github.com/kballard/go-shellquote v0.0.0-20180428030007-95032a82bc51 // indirect
	github.com/klauspost/compress v1.17.11 // indirect
	github.com/lufia/plan9stats v0.0.0-20240909124753-873cd0166683 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/mattn/go-sqlite3 v1.14.24 // indirect
	github.com/munnerz/goautoneg v0.0.0-20191010083416-a7dc8b61c822 // indirect
	github.com/ncruces/go-sqlite3 v0.24.0 // indirect
	github.com/ncruces/go-strftime v0.1.9 // indirect
	github.com/ncruces/julianday v1.0.0 // indirect
	github.com/onsi/ginkgo/v2 v2.22.2 // indirect
	github.com/pierrec/lz4/v4 v4.1.22 // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	github.com/power-devops/perfstat v0.0.0-20240221224432-82ca36839d55 // indirect
	github.com/prometheus/client_golang v1.21.1 // indirect
	github.com/prometheus/client_model v0.6.1 // indirect
	github.com/prometheus/common v0.62.0 // indirect
	github.com/prometheus/procfs v0.15.1 // indirect
	github.com/quic-go/quic-go v0.50.0 // indirect
	github.com/rcrowley/go-metrics v0.0.0-20201227073835-cf1acfcdf475 // indirect
	github.com/remyoudompheng/bigfft v0.0.0-20230129092748-24d4a6f8daec // indirect
	github.com/shirou/gopsutil/v4 v4.25.2 // indirect
	github.com/shoenig/go-m1cpu v0.1.6 // indirect
	github.com/stretchr/objx v0.5.2 // indirect
	github.com/stretchr/testify v1.10.0 // indirect
	github.com/syncthing/notify v0.0.0-20250207082249-f0fa8f99c2bc // indirect
	github.com/syndtr/goleveldb v1.0.1-0.20220721030215-126854af5e6d // indirect
	github.com/tetratelabs/wazero v1.9.0 // indirect
	github.com/thejerf/suture/v4 v4.0.6 // indirect
	github.com/tklauser/go-sysconf v0.3.14 // indirect
	github.com/tklauser/numcpus v0.9.0 // indirect
	github.com/vitrun/qart v0.0.0-20160531060029-bf64b92db6b0 // indirect
	github.com/yusufpapurcu/wmi v1.2.4 // indirect
	go.uber.org/mock v0.5.0 // indirect
	golang.org/x/crypto v0.36.0 // indirect
	golang.org/x/exp v0.0.0-20250106191152-7588d65b2ba8 // indirect
	golang.org/x/mobile v0.0.0-20250305212854-3a7bc9f8a4de // indirect
	golang.org/x/mod v0.24.0 // indirect
	golang.org/x/net v0.37.0 // indirect
	golang.org/x/sync v0.12.0 // indirect
	golang.org/x/sys v0.31.0 // indirect
	golang.org/x/text v0.23.0 // indirect
	golang.org/x/time v0.11.0 // indirect
	golang.org/x/tools v0.31.0 // indirect
	google.golang.org/protobuf v1.36.5 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
	modernc.org/libc v1.61.13 // indirect
	modernc.org/mathutil v1.7.1 // indirect
	modernc.org/memory v1.8.2 // indirect
	modernc.org/sqlite v1.36.0 // indirect
)

// gopsutil vanilla does not build on iOS. In the below fork some files are removed (iostat_darwin_cgo.go, iostat_drawin.c/.h)
// To update to a newer version, replace the 'v4.2.**'  with 'master', then run go mod tidy
replace github.com/shirou/gopsutil/v4 => github.com/pixelspark/gopsutil/v4 v4.24.9-0.20240922111650-71ae9b06ea66

replace github.com/gobwas/glob v0.2.3 => github.com/calmh/glob v0.0.0-20220615080505-1d823af5017b
