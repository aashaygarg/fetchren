import 'package:fetchren_core/fetchren_core.dart';
import 'package:fetchren_core_testing/fetchren_core_testing.dart';

void main() {
  runWorkspaceRepositoryContract(
    'InMemoryWorkspaceRepository',
    () async => InMemoryWorkspaceRepository(),
  );
}
