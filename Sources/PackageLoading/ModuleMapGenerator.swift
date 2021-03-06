/*
 This source file is part of the Swift.org open source project
 
 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception
 
 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basic
import Utility
import PackageModel

public let moduleMapFilename = "module.modulemap"

/// A protocol for modules which might have a modulemap.
protocol ModuleMapProtocol {

    var moduleMapPath: AbsolutePath { get }

    var moduleMapDirectory: AbsolutePath { get }
}

extension ModuleMapProtocol {
    public var moduleMapPath: AbsolutePath {
        return moduleMapDirectory.appending(component: moduleMapFilename)
    }
}

extension CModule: ModuleMapProtocol {
    var moduleMapDirectory: AbsolutePath {
        return path
    }
}

extension ClangModule: ModuleMapProtocol {
    var moduleMapDirectory: AbsolutePath {
        return includeDir
    }
}

/// A modulemap generator for clang modules.
///
/// Modulemap is generated under the following rules provided it is not already present in include directory:
///
/// * "include/foo/foo.h" exists and `foo` is the only directory under include directory.
///    Generates: `umbrella header "/path/to/include/foo/foo.h"`
/// * "include/foo.h" exists and include contains no other directory.
///    Generates: `umbrella header "/path/to/include/foo.h"`
/// *  Otherwise in all other cases.
///    Generates: `umbrella "path/to/include"`
public struct ModuleMapGenerator {

    /// The clang module to operate on.
    private let module: ClangModule

    /// The file system to be used.
    private var fileSystem: FileSystem

    /// Stream on which warnings will be emitted.
    private let warningStream: OutputByteStream

    public init(for module: ClangModule, fileSystem: FileSystem = localFileSystem, warningStream: OutputByteStream = stdoutStream) {
        self.module = module
        self.fileSystem = fileSystem
        self.warningStream = warningStream
    }

    /// A link-declaration specifies a library or framework
    /// against which a program should be linked.
    /// More info: http://clang.llvm.org/docs/Modules.html#link-declaration
    /// A `library` modulemap style uses `link` flag for link-declaration where
    /// as a `framework` uses `link framework` flag and a framework module.
    public enum ModuleMapStyle {
        case library
        case framework

        /// Link declaration flag to be used in modulemap.
        var linkDeclFlag: String {
            switch self {
            case .library:
                return "link"
            case .framework:
                return "link framework"
            }
        }

        var moduleDeclQualifier: String? {
            switch self {
            case .library:
                return nil
            case .framework:
                return "framework"
            }
        }
    }

    public enum ModuleMapError: Swift.Error {
        case unsupportedIncludeLayoutForModule(String)
    }

    /// Create the synthesized module map, if necessary.
    /// Note: modulemap is not generated for test modules.
    //
    // FIXME: We recompute the generated modulemap's path when building swift
    // modules in `XccFlags(prefix: String)` there shouldn't be need to redo
    // this there but is difficult in current architecture.
    public mutating func generateModuleMap(inDir wd: AbsolutePath, modulemapStyle: ModuleMapStyle = .library) throws {
        // Don't generate modulemap for a Test module.
        guard !module.isTest else {
            return
        }

        ///Return if module map is already present
        guard !fileSystem.isFile(module.moduleMapPath) else {
            return
        }

        let includeDir = module.includeDir
        // Warn and return if no include directory.
        guard fileSystem.isDirectory(includeDir) else {
            warningStream <<< "warning: No include directory found for module '\(module.name)'. A library can not be imported without any public headers."
            warningStream.flush()
            return
        }
        
        let walked = try fileSystem.getDirectoryContents(includeDir).map{ includeDir.appending(component: $0) }
        
        let files = walked.filter{ fileSystem.isFile($0) && $0.suffix == ".h" }
        let dirs = walked.filter{ fileSystem.isDirectory($0) }

        let umbrellaHeaderFlat = includeDir.appending(component: module.c99name + ".h")
        if fileSystem.isFile(umbrellaHeaderFlat) {
            guard dirs.isEmpty else { throw ModuleMapError.unsupportedIncludeLayoutForModule(module.name) }
            try createModuleMap(inDir: wd, type: .header(umbrellaHeaderFlat), modulemapStyle: modulemapStyle)
            return
        }
        diagnoseInvalidUmbrellaHeader(includeDir)

        let umbrellaHeader = includeDir.appending(components: module.c99name, module.c99name + ".h")
        if fileSystem.isFile(umbrellaHeader) {
            guard dirs.count == 1 && files.isEmpty else { throw ModuleMapError.unsupportedIncludeLayoutForModule(module.name) }
            try createModuleMap(inDir: wd, type: .header(umbrellaHeader), modulemapStyle: modulemapStyle)
            return
        }
        diagnoseInvalidUmbrellaHeader(includeDir.appending(component: module.c99name))

        try createModuleMap(inDir: wd, type: .directory(includeDir), modulemapStyle: modulemapStyle)
    }

    /// Warn user if in case module name and c99name are different and there is a
    /// `name.h` umbrella header.
    private func diagnoseInvalidUmbrellaHeader(_ path: AbsolutePath) {
        let umbrellaHeader = path.appending(component: module.c99name + ".h")
        let invalidUmbrellaHeader = path.appending(component: module.name + ".h")
        if module.c99name != module.name && fileSystem.isFile(invalidUmbrellaHeader) {
            warningStream <<< "warning: \(invalidUmbrellaHeader.asString) should be renamed to \(umbrellaHeader.asString) to be used as an umbrella header"
            warningStream.flush()
        }
    }

    private enum UmbrellaType {
        case header(AbsolutePath)
        case directory(AbsolutePath)
    }
    
    private mutating func createModuleMap(inDir wd: AbsolutePath, type: UmbrellaType, modulemapStyle: ModuleMapStyle) throws {
        let stream = BufferedOutputByteStream()

        if let qualifier = modulemapStyle.moduleDeclQualifier {
            stream <<< qualifier <<< " "
        }
        stream <<< "module \(module.c99name) {\n"
        switch type {
        case .header(let header):
            stream <<< "    umbrella header \"\(header.asString)\"\n"
        case .directory(let path):
            stream <<< "    umbrella \"\(path.asString)\"\n"
        }
        stream <<< "    \(modulemapStyle.linkDeclFlag) \"\(module.c99name)\"\n"
        stream <<< "    export *\n"
        stream <<< "}\n"

        // FIXME: This doesn't belong here.
        try fileSystem.createDirectory(wd, recursive: true)

        let file = wd.appending(component: moduleMapFilename)
        try fileSystem.writeFileContents(file, bytes: stream.bytes)
    }
}
