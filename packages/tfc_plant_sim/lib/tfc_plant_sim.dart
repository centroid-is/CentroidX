/// A fake plant for the test bench: OPC UA servers stood up from a spec.
///
/// See the package README for what belongs in a spec and what must never be
/// committed to this repository.
library;

export 'src/plant.dart' show FakePlant, RunningServer, kIteratePeriod;
export 'src/spec.dart'
    show Motion, MemberSpec, NodeSpec, PlantSpec, PlantSpecError, ServerSpec, TypeSpec;
