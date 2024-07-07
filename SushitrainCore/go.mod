module t-shaped.nl/sushitrain/v2

go 1.22.4

require (
	github.com/gotd/contrib v0.20.0
	github.com/syncthing/syncthing v1.27.9
)

require (
	github.com/Azure/go-ntlmssp v0.0.0-20221128193559-754e69321358 // indirect
	github.com/beorn7/perks v1.0.1 // indirect
	github.com/calmh/incontainer v1.0.0 // indirect
	github.com/calmh/xdr v1.1.0 // indirect
	github.com/ccding/go-stun v0.1.4 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/chmduquesne/rollinghash v4.0.0+incompatible // indirect
	github.com/davecgh/go-spew v1.1.1 // indirect
	github.com/go-asn1-ber/asn1-ber v1.5.7 // indirect
	github.com/go-ldap/ldap/v3 v3.4.8 // indirect
	github.com/go-ole/go-ole v1.3.0 // indirect
	github.com/go-task/slim-sprig/v3 v3.0.0 // indirect
	github.com/gobwas/glob v0.2.3 // indirect
	github.com/gogo/protobuf v1.3.2 // indirect
	github.com/golang/snappy v0.0.4 // indirect
	github.com/google/pprof v0.0.0-20240528025155-186aa0362fba // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/greatroar/blobloom v0.8.0 // indirect
	github.com/hashicorp/golang-lru/v2 v2.0.7 // indirect
	github.com/jackpal/gateway v1.0.15 // indirect
	github.com/jackpal/go-nat-pmp v1.0.2 // indirect
	github.com/julienschmidt/httprouter v1.3.0 // indirect
	github.com/kballard/go-shellquote v0.0.0-20180428030007-95032a82bc51 // indirect
	github.com/klauspost/cpuid/v2 v2.2.7 // indirect
	github.com/minio/sha256-simd v1.0.1 // indirect
	github.com/miscreant/miscreant.go v0.0.0-20200214223636-26d376326b75 // indirect
	github.com/onsi/ginkgo/v2 v2.19.0 // indirect
	github.com/pierrec/lz4/v4 v4.1.21 // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	github.com/power-devops/perfstat v0.0.0-20240221224432-82ca36839d55 // indirect
	github.com/prometheus/client_golang v1.19.1 // indirect
	github.com/prometheus/client_model v0.6.1 // indirect
	github.com/prometheus/common v0.54.0 // indirect
	github.com/prometheus/procfs v0.15.1 // indirect
	github.com/quic-go/quic-go v0.44.0 // indirect
	github.com/rcrowley/go-metrics v0.0.0-20201227073835-cf1acfcdf475 // indirect
	github.com/shirou/gopsutil/v3 v3.24.5 // indirect
	github.com/stretchr/objx v0.5.2 // indirect
	github.com/stretchr/testify v1.9.0 // indirect
	github.com/syncthing/notify v0.0.0-20210616190510-c6b7342338d2 // indirect
	github.com/syndtr/goleveldb v1.0.1-0.20220721030215-126854af5e6d // indirect
	github.com/thejerf/suture/v4 v4.0.5 // indirect
	github.com/vitrun/qart v0.0.0-20160531060029-bf64b92db6b0 // indirect
	github.com/yusufpapurcu/wmi v1.2.4 // indirect
	go.uber.org/mock v0.4.0 // indirect
	golang.org/x/crypto v0.25.0 // indirect
	golang.org/x/exp v0.0.0-20240531132922-fd00a4e0eefc // indirect
	golang.org/x/mobile v0.0.0-20240716161057-1ad2df20a8b6 // indirect
	golang.org/x/mod v0.19.0 // indirect
	golang.org/x/net v0.27.0 // indirect
	golang.org/x/sync v0.7.0 // indirect
	golang.org/x/sys v0.22.0 // indirect
	golang.org/x/text v0.16.0 // indirect
	golang.org/x/time v0.5.0 // indirect
	golang.org/x/tools v0.23.0 // indirect
	google.golang.org/protobuf v1.34.1 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)

////replace github.com/syncthing/syncthing => github.com/pixelspark/syncthing sushi
//replace github.com/syncthing/syncthing => github.com/pixelspark/syncthing v1.27.10-0.20240708184208-1148559416e2
replace github.com/syncthing/syncthing => /Users/tommy/Repos/MobiusSyncSyncthing

replace github.com/shirou/gopsutil/v3 => github.com/SimonPickup/gopsutil/v3 v3.24.6

replace github.com/gobwas/glob v0.2.3 => github.com/calmh/glob v0.0.0-20220615080505-1d823af5017b
