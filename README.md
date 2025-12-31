# Bedrock Raft

[![Build Status](https://github.com/bedrock-kv/raft/actions/workflows/elixir_ci.yaml/badge.svg)](https://github.com/bedrock-kv/raft/actions/workflows/elixir_ci.yaml?branch=main)
[![Coverage Status](https://coveralls.io/repos/github/bedrock-kv/raft/badge.svg?branch=main)](https://coveralls.io/github/bedrock-kv/raft?branch=main)

An implementation of the RAFT consensus algorithm in Elixir that doesn't force a lot of opinions. You can bake the protocol into your own genservers, send messages and manage the logs how you like.

## Installation

```elixir
def deps do
  [
    {:bedrock_raft, "~> 0.9"}
  ]
end
```
