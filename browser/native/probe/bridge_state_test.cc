#include "workspace_bridge_state.h"

#include <cassert>
#include <iostream>

int main() {
  winmux::WorkspaceBridgeState state;
  assert(!state.CanRetry(0));
  assert(!state.IsConnected(0));
  assert(!state.Authenticate(0));
  assert(!state.Disconnect(0));

  auto first = state.BeginAttempt();
  assert(state.IsConnecting(first));
  assert(state.Disconnect(first) == 1);
  assert(!state.Disconnect(first));  // Interruption + invalidation: one retry.
  assert(!state.Authenticate(first));  // Late reply after a timeout.
  assert(state.CanRetry(first));

  auto second = state.BeginAttempt();
  assert(!state.CanRetry(first));
  assert(!state.Authenticate(first));
  assert(!state.Disconnect(first));  // An old proxy cannot disrupt a new one.
  assert(state.Disconnect(second) == 2);
  for (unsigned delay : {4u, 8u, 16u, 30u, 30u, 30u}) {
    auto generation = state.BeginAttempt();
    assert(state.Disconnect(generation) == delay);
  }

  auto healthy = state.BeginAttempt();
  assert(state.Authenticate(healthy));
  assert(state.IsConnected(healthy));
  assert(!state.IsConnecting(healthy));  // An old negotiation timer is inert.
  assert(!state.Authenticate(healthy));  // Duplicate acknowledgement is inert.
  assert(state.authenticated_connections() == 1);
  assert(state.Disconnect(healthy) == 1);  // Recovery resets backoff.
  assert(!state.IsConnected(healthy));
  auto recovered = state.BeginAttempt();
  assert(state.Authenticate(recovered));
  assert(state.IsConnected(recovered));
  assert(!state.IsConnected(healthy));
  assert(state.authenticated_connections() == 2);
  assert(!state.Disconnect(healthy));
  std::cout << "Bridge generation, duplicate callback, timeout and backoff checks passed\n";
}
