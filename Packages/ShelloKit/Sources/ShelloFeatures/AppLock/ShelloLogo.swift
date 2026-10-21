import SwiftUI

/// Shello's logo from the UI design (docs/ui/ui_v1/canvas/System.dc.html): a speech bubble that
/// holds a prompt, with the accent cursor after it.
struct ShelloLogo: View {
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / 32
            ZStack(alignment: .topLeading) {
                Bubble()
                    .fill(Palette.textPrimary)
                Chevron()
                    .stroke(
                        Palette.ground, style: StrokeStyle(lineWidth: 2.4 * scale, lineCap: .round, lineJoin: .round))
                RoundedRectangle(cornerRadius: scale)
                    .fill(Palette.accent)
                    .frame(width: 7 * scale, height: 2.8 * scale)
                    .offset(x: 15.5 * scale, y: 16 * scale)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// A rounded rectangle with a tail at the bottom left, on a 32-point grid.
    private struct Bubble: Shape {
        func path(in rect: CGRect) -> Path {
            let grid = Grid(rect)
            var path = Path()
            path.move(to: grid[10, 2])
            path.addLine(to: grid[22, 2])
            path.addArc(
                center: grid[22, 10], radius: grid.length(8), startAngle: .degrees(-90), endAngle: .zero,
                clockwise: false)
            path.addLine(to: grid[30, 18])
            path.addArc(
                center: grid[22, 18], radius: grid.length(8), startAngle: .zero, endAngle: .degrees(90),
                clockwise: false)
            path.addLine(to: grid[13, 26])
            path.addLine(to: grid[8, 30.5])
            path.addLine(to: grid[8, 25.75])
            // The tail cuts into the bottom-left corner, whose arc starts where the tail ends.
            path.addArc(
                center: grid[10, 18], radius: grid.length(8), startAngle: .degrees(104.47),
                endAngle: .degrees(180), clockwise: false)
            path.addLine(to: grid[2, 10])
            path.addArc(
                center: grid[10, 10], radius: grid.length(8), startAngle: .degrees(180),
                endAngle: .degrees(270), clockwise: false)
            path.closeSubpath()
            return path
        }
    }

    /// The prompt's `>`.
    private struct Chevron: Shape {
        func path(in rect: CGRect) -> Path {
            let grid = Grid(rect)
            var path = Path()
            path.move(to: grid[9.5, 10.5])
            path.addLine(to: grid[14, 14])
            path.addLine(to: grid[9.5, 17.5])
            return path
        }
    }

    /// The design's 32 by 32 grid, fitted into a rectangle. Shapes draw off the main actor.
    nonisolated private struct Grid {
        let origin: CGPoint
        let scale: CGFloat

        init(_ rect: CGRect) {
            origin = rect.origin
            scale = min(rect.width, rect.height) / 32
        }

        subscript(x: CGFloat, y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        func length(_ length: CGFloat) -> CGFloat {
            length * scale
        }
    }
}

#Preview {
    ShelloLogo()
        .frame(width: 120, height: 120)
        .padding()
        .background(Palette.ground)
}
