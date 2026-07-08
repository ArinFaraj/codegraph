import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Stops descending into nested function bodies so hazards/returns in closures
/// and local functions are not attributed to the enclosing method.
mixin NestedFunctionBoundary on RecursiveAstVisitor<void> {
  @override
  void visitFunctionExpression(FunctionExpression node) {}

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {}
}
