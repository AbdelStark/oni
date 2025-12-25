/// P2P subsystem placeholder.
///
/// The full implementation will provide:
/// - message framing and codecs
/// - peer manager + address manager
/// - per-peer connection processes
/// - relay and IBD coordination

pub type PeerId {
  PeerId(String)
}

pub fn peer_id(name: String) -> PeerId {
  PeerId(name)
}
