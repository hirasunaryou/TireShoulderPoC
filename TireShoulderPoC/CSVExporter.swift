import Foundation

enum CSVExporter {
    static func export(result: ComparisonResult,
                       newName: String,
                       usedName: String) throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let fileName = "tire-profile-\(timestamp()).csv"
        let fileURL = temporaryDirectory.appendingPathComponent(fileName)

        var lines: [String] = []
        lines.append("# Tire Shoulder PoC")
        lines.append("# new,\(newName)")
        lines.append("# used,\(usedName)")
        lines.append("# blue_rms_mm,\(String(format: "%.4f", result.alignmentRMSMM))")
        lines.append("# mean_abs_delta_mm,\(String(format: "%.4f", result.meanAbsDeltaMM))")
        lines.append("# p95_abs_delta_mm,\(String(format: "%.4f", result.p95AbsDeltaMM))")
        lines.append("# max_abs_delta_mm,\(String(format: "%.4f", result.maxAbsDeltaMM))")
        lines.append("# estimated_shoulder_wear_mm,\(String(format: "%.4f", result.estimatedShoulderWearMM))")
        lines.append("x_mm,new_y_mm,used_y_mm,delta_mm")

        for sample in result.samples {
            lines.append([
                String(format: "%.4f", sample.xMM),
                String(format: "%.4f", sample.newYMM),
                String(format: "%.4f", sample.usedYMM),
                String(format: "%.4f", sample.deltaMM)
            ].joined(separator: ","))
        }

        let csvText = lines.joined(separator: "\n")

        do {
            try csvText.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            throw PoCError.csvExportFailed(error.localizedDescription)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
