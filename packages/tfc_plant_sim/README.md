# tfc_plant_sim — a fake plant

OPC UA servers stood up from a written spec, so the HMI, the backend and the
relay can be run and tested against something that behaves like a plant
without a plant being there.

```sh
dart run tfc_plant_sim:plant --spec fixtures/demo_plant.yaml
```

It prints one endpoint per server and keeps running until Ctrl-C.

## The spec is invented, and stays that way

Everything under `fixtures/` is **fiction**: made-up servers, machines and
tags, chosen to exercise the shapes that have broken things, not copied from
any plant. Nothing derived from a customer site — a config dump, a scrubbed
config dump, a slice of history, a list of their tag names — belongs in this
repository, in this package or in any fixture.

A spec taken from a real plant lives **outside the repository**, and the
tooling refuses to write one inside it. Point the bench at one with:

```sh
dart run tfc_plant_sim:plant --spec "$CENTROIDX_BENCH_SNAPSHOT/plant.yaml"
```

## What the shapes are for

Each node kind in `demo_plant.yaml` is there because something broke on it:

| Shape | What it caught |
|---|---|
| a struct whose member is an enum | a panel colours equipment from enum *names*; without the type dictionary every state reads "unknown" (violet) |
| a node that notifies once and never again | a configured setpoint is a constant, and a freshness sweep with no keep-alive badges it stale ten seconds in |
| a rate that sits at zero | "no data" and "zero" look identical on a chart, and only one of them is a fault |
| a node that is not there | a mapping pointing at a node the PLC does not have answers `BadNodeIdUnknown`, which reads to an operator as an empty page |

Add a shape when a defect teaches you one, and say in the table what it
caught.
