// Test-only mkfs helper: the snapshot ships no croit-flashstore-tool, so this formats a device and
// stores the OSD identity + superblock through the repo's public API.
// usage: frs_mkfs <dev-spec> <osd-id> <osd-uuid> <cluster-fsid> <cephx-key-base64> <shards>
use osd::meta::MetaStore;
use osd::{Identity, nvmestore};

fn uuid(s: &str) -> [u8; 16] {
    let h: String = s.chars().filter(|c| *c != '-').collect();
    let mut b = [0u8; 16];
    for (i, x) in b.iter_mut().enumerate() {
        *x = u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap();
    }
    b
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let id: i32 = a[2].parse().unwrap();
    let shards: u32 = a[6].parse().unwrap();
    let spec = nvme::any::DevSpec::parse(&a[1]).unwrap();
    let ctrl = nvme::any::AnyCtrl::open_exclusive_create(&spec, true).unwrap();
    let g = ctrl.geometry();
    let bytes = g.lba_size as u64 * g.lba_count;
    println!("geometry: {g:?} bytes={bytes}");
    let mut p = nvmestore::mkfs_params_for(bytes, shards);
    p.osd_id = id;
    p.osd_fsid = uuid(&a[3]);
    p.cluster_fsid = uuid(&a[4]);
    p.allow_volatile_cache = true;
    p.mkfs_time = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    println!("mkfs params: {p:?}");
    nvmestore::mkfs_dev(&ctrl, &p).unwrap();
    let (st, replay) = nvmestore::mount_dev(&ctrl).unwrap();
    println!("mounted, replay stats: {replay:?}");
    let mut s = osd::open_nvme(st).unwrap();
    let mut idn = Identity {
        whoami: id,
        cluster_fsid: Default::default(),
        osd_fsid: Default::default(),
        key: a[5].clone(),
        crush_device_class: "nvme".into(),
        created_at: "frs_mkfs".into(),
        ceph_version_when_created: "frs_mkfs".into(),
    };
    idn.cluster_fsid.0 = p.cluster_fsid;
    idn.osd_fsid.0 = p.osd_fsid;
    s.meta.store_identity(&idn).unwrap();
    let sb = messages::OsdSuperblock {
        cluster_fsid: idn.cluster_fsid,
        whoami: id,
        osd_fsid: idn.osd_fsid,
        compat_features: messages::CompatSet::osd_initial(),
        ..Default::default()
    };
    s.meta.store_superblock(&sb).unwrap();
    println!("identity + superblock stored for osd.{id}");
}
