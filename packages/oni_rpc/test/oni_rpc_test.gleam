import gleeunit
import gleeunit/should
import oni_rpc

pub fn main() {
  gleeunit.main()
}

pub fn hello_test() {
  oni_rpc.hello() |> should.equal("oni_rpc (scaffold)")
}
