/*
 This source file is part of the Swift.org open source project

 Copyright 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import struct PackageDescription.Version

/// An abstract definition for a set of versions.
public enum VersionSetSpecifier: Equatable {
    /// The universal set.
    case any

    /// The empty set.
    case empty

    /// A non-empty range of version.
    case range(Range<Version>)

    /// Compute the intersection of two set specifiers.
    public func intersection(_ rhs: VersionSetSpecifier) -> VersionSetSpecifier {
        switch (self, rhs) {
        case (.any, _):
            return rhs
        case (_, .any):
            return self
        case (.empty, _):
            return .empty
        case (_, .empty):
            return .empty
        case (.range(let lhs), .range(let rhs)):
            let start = Swift.max(lhs.lowerBound, rhs.lowerBound)
            let end = Swift.min(lhs.upperBound, rhs.upperBound)
            if start < end {
                return .range(start..<end)
            } else {
                return .empty
            }
        default:
            // FIXME: Compiler should be able to prove this? https://bugs.swift.org/browse/SR-2221
            fatalError("not reachable")
        }
    }

    /// Check if the set contains a version.
    public func contains(_ version: Version) -> Bool {
        switch self {
        case .empty:
            return false
        case .range(let range):
            return range.contains(version)
        case .any:
            return true
        }
    }
}
public func ==(_ lhs: VersionSetSpecifier, _ rhs: VersionSetSpecifier) -> Bool {
    switch (lhs, rhs) {
    case (.any, .any):
        return true
    case (.any, _):
        return false
    case (.empty, .empty):
        return true
    case (.empty, _):
        return false
    case (.range(let lhs), .range(let rhs)):
        return lhs == rhs
    case (.range, _):
        return false
    }
}

/// An identifier which unambiguously references a package container.
///
/// This identifier is used to abstractly refer to another container when
/// encoding dependencies across packages.
public protocol PackageContainerIdentifier: Hashable { }

/// A container of packages.
///
/// This is the top-level unit of package resolution, i.e. the unit at which
/// versions are associated.
///
/// It represents a package container (e.g., a source repository) which can be
/// identified unambiguously and which contains a set of available package
/// versions and the ability to retrieve the dependency constraints for each of
/// those versions.
///
/// We use the "container" terminology here to differentiate between two
/// conceptual notions of what the package is: (1) informally, the repository
/// containing the package, but from which a package cannot be loaded by itself
/// and (2) the repository at a particular version, at which point the package
/// can be loaded and dependencies enumerated.
///
/// This is also designed in such a way to extend naturally to multiple packages
/// being contained within a single repository, should we choose to support that
/// later.
public protocol PackageContainer {
    /// The type of packages contained.
    associatedtype Identifier: PackageContainerIdentifier

    /// The identifier for the package.
    var identifier: Identifier { get }

    /// Get the list of versions which are available for the package.
    ///
    /// The list will be returned in sorted order, with the latest version last.
    //
    // FIXME: It is possible this protocol could one day be more efficient if it
    // returned versions more lazily, e.g., if we could fetch them iteratively
    // from the server. This might mean we wouldn't need to pull down as much
    // content.
    var versions: [Version] { get }

    /// Fetch the declared dependencies for a particular version.
    ///
    /// - precondition: `versions.contains(version)`
    func getDependencies(at version: Version) -> [PackageContainerConstraint<Identifier>]
}

/// An interface for resolving package containers.
public protocol PackageContainerProvider {
    associatedtype Container: PackageContainer

    /// Get the container for a particular identifier.
    ///
    /// - Throws: If the package container could not be resolved or loaded.
    func getContainer(for identifier: Container.Identifier) throws -> Container
}

/// An individual constraint onto a container.
public struct PackageContainerConstraint<T> where T: PackageContainerIdentifier {
    public typealias Identifier = T

    /// The identifier for the container the constraint is on.
    public let identifier: Identifier

    /// The version requirements.
    public let versionRequirement: VersionSetSpecifier

    /// Create a constraint requiring the given `container` satisfying the
    /// `versionRequirement`.
    public init(container identifier: Identifier, versionRequirement: VersionSetSpecifier) {
        self.identifier = identifier
        self.versionRequirement = versionRequirement
    }
}

/// Delegate interface for dependency resoler status.
public protocol DependencyResolverDelegate {
    associatedtype Identifier: PackageContainerIdentifier

    /// Called when a new container is being considered.
    func added(container identifier: Identifier)
}

/// A bound version for a package within an assignment.
//
// FIXME: This should be nested, but cannot be currently.
enum BoundVersion {
    /// The assignment should not include the package.
    ///
    /// This is different from the absence of an assignment for a particular
    /// package, which only indicates the assignment is agnostic to its
    /// version. This value signifies the package *may not* be present.
    case excluded

    /// The version of the package to include.
    case version(Version)
}

/// An assignment of versions for a set of packages.
///
/// This is intended to be an efficient data structure for accumulating a set of
/// version assignments along with efficient access to the derived information
/// about the assignment (for example, the unified set of constraints it
/// induces).
//
// FIXME: Actually make efficient.
struct VersionAssignment<C> where C: PackageContainer {
    typealias Container = C
    typealias Identifier = Container.Identifier

    /// The assignment records.
    //
    // FIXME: Does it really make sense to key on the identifier here. Should we
    // require referential equality of containers and use that to simplify?
    private var assignments: [Identifier: (container: Container, binding: BoundVersion)]

    /// Create an empty assignment.
    init() {
        assignments = [:]
    }

    /// The assignment for the given `container`.
    subscript(container: Container) -> BoundVersion? {
        get {
            return assignments[container.identifier]?.binding
        }
        set {
            // We disallow deletion.
            let newBinding = newValue!

            // Validate this is a valid assignment.
            assert(isValid(binding: newBinding, for: container))

            assignments[container.identifier] = (container: container, binding: newBinding)
        }
    }

    /// The combined version constraints induced by the assignment.
    ///
    /// This consists of the merged constraints which need to be satisfied on
    /// each package as a result of the versions selected in the assignment.
    //
    // FIXME: We need to cache this.
    var constraints: [Identifier: VersionSetSpecifier] {
        // Collect all of the constraints.
        var result = [Identifier: VersionSetSpecifier]()
        for (_, (container: container, binding: binding)) in assignments {
            switch binding {
            case .excluded:
                // If the package is excluded, it doesn't contribute.
                continue

            case .version(let version):
                // If we have a version, add the constraints from that package version.
                //
                // FIXME: We should cache this too, possibly at a layer
                // different than above (like the entry record).
                for constraint in container.getDependencies(at: version) {
                    // Merge in the constraint.
                    let i = constraint.identifier
                    if let existing = result[i] {
                        result[i] = existing.intersection(constraint.versionRequirement)
                    } else {
                        result[i] = constraint.versionRequirement
                    }
                }
            }
        }
        return result
    }

    /// Check if the given `binding` for `container` is valid within the assignment.
    //
    // FIXME: This is currently very inefficient.
    func isValid(binding: BoundVersion, for container: Container) -> Bool {
        switch binding {
        case .excluded:
            // A package can be excluded if there are no constraints on the
            // package (it has not been requested by any other package in the
            // assignment).
            return constraints[container.identifier] == nil

        case .version(let version):
            // A version is valid if it is contained in the constraints, or there are no constraints.
            if let versionSet = constraints[container.identifier] {
                return versionSet.contains(version)
            } else {
                return true
            }
        }
    }
}

/// A general purpose package dependency resolver.
///
/// This is a general purpose solver for the problem of:
///
/// Given an input list of constraints, where each constraint identifies a
/// container and version requirements, and, where each container supplies a
/// list of additional constraints ("dependencies") for an individual version,
/// then, choose an assignment of containers to versions such that:
///
/// 1. The assignment is complete: there exists an assignment for each container
/// listed in the union of the input constraint list and the dependency list for
/// every container in the assignment at the assigned version.
///
/// 2. The assignment is correct: the assigned version satisfies each constraint
/// referencing its matching container.
///
/// 3. The assignment is maximal: there is no other assignment satisfying #1 and
/// #2 such that all assigned version are greater than or equal to the versions
/// assigned in the result.
///
/// NOTE: It does not follow from #3 that this solver attempts to give an
/// "optimal" result. There may be many possible solutions satisfying #1, #2,
/// and #3, and optimality requires additional information (e.g. a
/// prioritization among packages).
///
/// As described, this problem is NP-complete (*). However, this solver does
/// *not* currently attempt to solve the full NP-complete problem, rather it
/// proceeds by first always attempting to choose the latest version of each
/// container under consideration. However, if this version is unavailable due
/// to the current choice of assignments, it will be rejected and no longer
/// considered.
///
/// This algorithm is sound (a valid solution satisfies the assignment
/// guarantees above), but *incomplete*; it may fail to find a valid solution to
/// a satisfiable input.
///
/// (*) Via reduction from 3-SAT: Introduce a package for each variable, with
/// two versions representing true and false. For each clause `C_n`, introduce a
/// package `P(C_n)` representing the clause, with three versions; one for each
/// satisfying assignment of values to a literal with the corresponding precise
/// constraint on the input packages. Finally, construct an input constraint
/// list including a dependency on each clause package `P(C_n)` and an
/// open-ended version constraint. The given input is satisfiable iff the input
/// 3-SAT instance is.
public class DependencyResolver<
    P: PackageContainerProvider,
    D: DependencyResolverDelegate
> where P.Container.Identifier == D.Identifier
{
    public typealias Provider = P
    public typealias Delegate = D
    public typealias Container = Provider.Container
    public typealias Identifier = Container.Identifier

    /// The type of the constraints the resolver operates on.
    ///
    /// Technically this is a container constraint, but that is currently the
    /// only kind of constraints we operate on.
    public typealias Constraint = PackageContainerConstraint<Identifier>

    /// The initial constraints.
    public let constraints: [Constraint]

    /// The container provider used to load package containers.
    public let provider: Provider

    /// The resolver's delegate.
    public let delegate: Delegate

    public init(
        constraints: [Constraint],
        provider: Provider,
        delegate: Delegate)
    {
        self.constraints = constraints
        self.provider = provider
        self.delegate = delegate
    }

    /// Execute the resolution algorithm to find a valid assignment of versions.
    public func resolve() throws -> [(container: Identifier, version: Version)] {
        // For now, we just load the transitive closure of the dependencies at
        // the latest version, and ignore the version requirements.

        func visit(_ identifier: Identifier) throws {
            // If we already have this identifier, skip it.
            if containers.keys.contains(identifier) {
                return
            }

            // Otherwise, load the container and visit its dependencies.
            let container = try getContainer(for: identifier)

            // Visit the dependencies at the latest version.
            //
            // FIXME: What if this dependency has no versions? We should
            // consider it unavailable.
            let latestVersion = container.versions.last!
            let constraints = container.getDependencies(at: latestVersion)

            for constraint in constraints {
                try visit(constraint.identifier)
            }
        }
        for constraint in constraints {
            try visit(constraint.identifier)
        }

        return containers.map { (identifier, container) in
            return (container: identifier, version: container.versions.last!)
        }
    }

    // MARK: Container Management

    /// The active set of managed containers.
    private var containers: [Identifier: Container] = [:]

    /// Get the container for the given identifier, loading it if necessary.
    private func getContainer(for identifier: Identifier) throws -> Container {
        // Return the cached container, if available.
        if let container = containers[identifier] {
            return container
        }

        // Otherwise, load it.
        return try addContainer(for: identifier)
    }

    /// Add a managed container.
    //
    // FIXME: In order to support concurrent fetching of dependencies, we need
    // to have some measure of asynchronicity here.
    private func addContainer(for identifier: Identifier) throws -> Container {
        assert(!containers.keys.contains(identifier))

        let container = try provider.getContainer(for: identifier)
        containers[identifier] = container

        // Validate the versions in the container.
        let versions = container.versions
        assert(versions.sorted() == versions, "container versions are improperly ordered")

        // Inform the delegate we are considering a new container.
        delegate.added(container: identifier)

        return container
    }
}
