import gleeunit
import gleeunit/should
import oni_p2p

pub fn main() {
  gleeunit.main()
}

pub fn peer_id_test() {
  oni_p2p.peer_id("p") |> should.equal(oni_p2p.PeerId("p"))
}
