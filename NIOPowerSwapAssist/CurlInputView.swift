import SwiftUI

struct CurlParseInputView: View {
    @Binding var isPresented: Bool
    let onCurlParsed: (InfoRequest) -> Void
    
    @State private var curlCommand: String = ""
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            VStack {
                TextEditor(text: $curlCommand)
                    .frame(height: 200)
                    .padding()
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                    .padding()
                
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                }
                
                Button("Parse and Execute") {
                    if let request = parseCurlCommand(curlCommand) {
                        onCurlParsed(request)
                        isPresented = false
                    }
                }
                .padding()
                .disabled(curlCommand.isEmpty)
            }
            .navigationTitle("Enter Curl Command")
            .navigationBarItems(trailing: Button("Cancel") {
                isPresented = false
            })
        }
    }
    
    private func parseCurlCommand(_ command: String) -> InfoRequest? {
        // Remove any extra whitespace and newlines
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Basic validation
        guard trimmedCommand.hasPrefix("curl") else {
            errorMessage = "Invalid curl command: Must start with 'curl'"
            return nil
        }
        
        // Extract URL
        guard let urlRange = trimmedCommand.range(of: "'https://[^']*'"),
              let url = URL(string: String(trimmedCommand[urlRange]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))) else {
            errorMessage = "Invalid curl command: Could not parse URL"
            return nil
        }
        
        // Extract headers
        var headers: [String: String] = [:]
        let headerPattern = "--header '([^:]+): ([^']*)'"
        if let regex = try? NSRegularExpression(pattern: headerPattern) {
            let matches = regex.matches(in: trimmedCommand, range: NSRange(trimmedCommand.startIndex..., in: trimmedCommand))
            for match in matches {
                if let headerNameRange = Range(match.range(at: 1), in: trimmedCommand),
                   let headerValueRange = Range(match.range(at: 2), in: trimmedCommand) {
                    let name = String(trimmedCommand[headerNameRange])
                    let value = String(trimmedCommand[headerValueRange])
                    headers[name] = value
                }
            }
        }
        
        // Create InfoRequest
        var request = InfoRequest()
        request.url = url
        request.headers = headers
        
        return request
    }
}
