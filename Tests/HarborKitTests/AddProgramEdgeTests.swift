import Foundation
import Testing
@testable import HarborKit

@Suite struct AddProgramEdgeTests {
    let fm = FileManager.default

    /// A fresh temp folder and a function that creates empty files (and their folders) inside it.
    func tree() throws -> (URL, (String) throws -> Void) {
        let base = fm.temporaryDirectory.appending(path: "harbor-edge-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, { path in
            let url = base.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        })
    }

    // MARK: #13

    /// A loose program in a folder of other games (`/Volumes/SSD/Games/tool.exe`): only the program is copied.
    @Test func aLooseProgramBesideOtherGamesDoesNotTakeTheirFolder() throws {
        let (base, touch) = try tree()
        for f in ["Games/tool.exe", "Games/Quest/Quest.exe", "Games/Quest/Data/quest.pak",
                  "Games/Racer/racer.exe", "Games/Racer/engine.dll"] { try touch(f) }
        #expect(AddProgram.programRoot(for: base.appending(path: "Games/tool.exe")) == nil)
    }

    /// `~/Sync/bin/tool.exe` beside a letter and photos: walking up from `bin` stops below `Sync`.
    @Test func walkingUpFromBinNeverTakesAFolderOfPersonalFiles() throws {
        let (base, touch) = try tree()
        for f in ["Sync/bin/tool.exe", "Sync/letter.pdf", "Sync/Photos/2026/beach.jpg"] { try touch(f) }
        let bin = base.appending(path: "Sync/bin").standardizedFileURL
        #expect(AddProgram.programRoot(for: base.appending(path: "Sync/bin/tool.exe")) == bin)
        // The same without a document at the top level: the photos sit one folder down.
        try fm.removeItem(at: base.appending(path: "Sync/letter.pdf"))
        #expect(AddProgram.programRoot(for: base.appending(path: "Sync/bin/tool.exe")) == bin)
    }

    /// Without DLLs or an Unreal `Engine` folder, subfolders come along only if nothing in them looks like
    /// someone else's: another program, personal documents, or the dot-files of a synced or working folder.
    @Test func subfoldersComeAlongOnlyWhenTheyLookLikeTheProgramsOwn() throws {
        let (base, touch) = try tree()
        for f in ["Old/game.exe", "Old/data/levels/one.dat", "Old/.DS_Store"] { try touch(f) }
        #expect(AddProgram.programRoot(for: base.appending(path: "Old/game.exe")) == base.appending(path: "Old").standardizedFileURL)
        for f in ["Work/tool.exe", "Work/project/.git/HEAD", "Work/project/notes.txt"] { try touch(f) }
        #expect(AddProgram.programRoot(for: base.appending(path: "Work/tool.exe")) == nil)
        for f in ["Dropbox/bin/tool.exe", "Dropbox/.dropbox", "Dropbox/Notes/todo.txt"] { try touch(f) }
        #expect(AddProgram.programRoot(for: base.appending(path: "Dropbox/bin/tool.exe"))
                == base.appending(path: "Dropbox/bin").standardizedFileURL)
        // Too many files to tell: only the program.
        try touch("Huge/tool.exe")
        for n in 0...AddProgram.unprovenFolderLimit { try touch("Huge/data/\(n).dat") }
        #expect(AddProgram.programRoot(for: base.appending(path: "Huge/tool.exe")) == nil)
    }

    @Test func cloudStorageRootsAreShared() {
        let cloud = fm.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage")
        for shared in ["", "Dropbox", "GoogleDrive-someone@example.com", "GoogleDrive-someone@example.com/My Drive"] {
            #expect(AddProgram.isSharedFolder(cloud.appending(path: shared)), "\(shared)")
        }
        #expect(!AddProgram.isSharedFolder(cloud.appending(path: "Dropbox/Games/Thing")))
    }
}
