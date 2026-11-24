import SwiftUI
import Testing
@testable import Harbor

/// Where the arrow keys lead in the library's grid. Seven tiles in rows of three:
///
///     0 1 2
///     3 4 5
///     6
@MainActor @Suite struct LibraryKeyboardTests {
    func index(after current: Int?, _ key: KeyEquivalent, count: Int = 7, columns: Int = 3) -> Int {
        LibraryView.tileIndex(after: current, pressing: key, count: count, columns: columns)
    }

    @Test func withoutASelectionEveryArrowSelectsTheFirstTile() {
        for key in [KeyEquivalent.leftArrow, .rightArrow, .upArrow, .downArrow] {
            #expect(index(after: nil, key) == 0)
        }
    }

    @Test func leftAndRightGoOnIntoTheNeighbouringRow() {
        #expect(index(after: 1, .rightArrow) == 2)
        #expect(index(after: 2, .rightArrow) == 3)
        #expect(index(after: 3, .leftArrow) == 2)
    }

    @Test func upAndDownStayInTheirColumn() {
        #expect(index(after: 1, .downArrow) == 4)
        #expect(index(after: 4, .upArrow) == 1)
        #expect(index(after: 3, .downArrow) == 6)
    }

    @Test func anArrowThatLeadsNowhereStaysWhereItIs() {
        #expect(index(after: 0, .leftArrow) == 0)
        #expect(index(after: 6, .rightArrow) == 6)
        #expect(index(after: 1, .upArrow) == 1)
        #expect(index(after: 6, .downArrow) == 6)
    }

    /// Nothing is below tiles 4 and 5, but there is a row below them: its last tile is the nearest.
    @Test func downAboveAShorterLastRowGoesToItsLastTile() {
        #expect(index(after: 4, .downArrow) == 6)
        #expect(index(after: 5, .downArrow) == 6)
    }

    @Test func aSingleColumnAndASingleTile() {
        #expect(index(after: 0, .downArrow, count: 3, columns: 1) == 1)
        #expect(index(after: 2, .downArrow, count: 3, columns: 1) == 2)
        for key in [KeyEquivalent.leftArrow, .rightArrow, .upArrow, .downArrow] {
            #expect(index(after: 0, key, count: 1, columns: 4) == 0)
        }
    }
}
