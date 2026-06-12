import SwiftUI
import WebKit

struct GraphView: View {
    @State private var searchText = ""
    @State private var graphData: GraphData?
    @State private var selectedNode: GraphNode?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索节点...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { refreshGraph() }
                if !searchText.isEmpty {
                    Button { searchText = ""; refreshGraph() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.borderless)
                }
                Button("刷新") { refreshGraph() }.buttonStyle(.borderless)
            }
            .padding(8).background(Color.primary.opacity(0.06)).cornerRadius(8).padding(8)

            if let data = graphData {
                ForceGraphWebView(graphData: data, onNodeTap: { nodeId in
                    selectedNode = data.nodes.first { $0.nodeId == nodeId }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
                Text("加载图谱...").foregroundColor(.secondary)
                Spacer()
            }

            if let node = selectedNode {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(node.label).font(.headline).lineLimit(1)
                        Spacer()
                        Text(String(repeating: "⭐", count: min(3, Int(node.importance * 3 + 1))))
                            .font(.caption2)
                        Button { selectedNode = nil } label: {
                            Image(systemName: "xmark").font(.caption)
                        }.buttonStyle(.borderless)
                    }
                    Text(node.preview).font(.caption).foregroundColor(.secondary).lineLimit(5)
                    Text("来源: \(node.group)").font(.caption2).foregroundColor(.secondary)
                }
                .padding(8)
                .frame(height: 120)
            }
        }
        .task { refreshGraph() }
    }

    private func refreshGraph() {
        graphData = GraphService.buildGraph(
            searchQuery: searchText.trimmingCharacters(in: .whitespaces),
            limit: searchText.isEmpty ? 50 : 30
        )
        selectedNode = nil
    }
}

struct ForceGraphWebView: NSViewRepresentable {
    let graphData: GraphData
    let onNodeTap: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "nodeTap")
        config.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let jsonData = try? JSONEncoder().encode(graphData),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        let html = forceGraphHTML(json: json)
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onNodeTap: onNodeTap)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onNodeTap: (String) -> Void

        init(onNodeTap: @escaping (String) -> Void) {
            self.onNodeTap = onNodeTap
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "nodeTap", let nodeId = message.body as? String {
                DispatchQueue.main.async { self.onNodeTap(nodeId) }
            }
        }
    }
}

func forceGraphHTML(json: String) -> String {
    """
    <!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>*{margin:0;padding:0}canvas{display:block}body{background:#1e1e2e;overflow:hidden}</style></head><body>
    <canvas id="c"></canvas>
    <script>
    const data = \(json);
    const canvas = document.getElementById('c');
    const ctx = canvas.getContext('2d');

    const colors = ['#a6e3a1','#89b4fa','#f9e2af','#f38ba8','#cba6f7','#94e2d5','#fab387','#b4befe'];
    const groupColors = {};
    let colorIdx = 0;
    function colorFor(g) { if(!groupColors[g]) groupColors[g]=colors[colorIdx++%colors.length]; return groupColors[g]; }

    const dpr = window.devicePixelRatio || 1;
    let W=window.innerWidth, H=window.innerHeight;
    canvas.width=W*dpr; canvas.height=H*dpr;
    canvas.style.width=W+'px'; canvas.style.height=H+'px';
    ctx.scale(dpr, dpr);
    window.onresize=()=>{ W=window.innerWidth; H=window.innerHeight; canvas.width=W*dpr; canvas.height=H*dpr; canvas.style.width=W+'px'; canvas.style.height=H+'px'; ctx.setTransform(dpr,0,0,dpr,0,0); };

    const nodes = data.nodes.map(n=>({...n, x:W/2+(Math.random()-0.5)*300, y:H/2+(Math.random()-0.5)*300, vx:0, vy:0}));
    const nodeMap = {};
    nodes.forEach(n=>nodeMap[n.nodeId]=n);

    const edges = data.edges.filter(e=>nodeMap[e.source]&&nodeMap[e.target]).map(e=>({...e, s:nodeMap[e.source], t:nodeMap[e.target]}));

    const nodeRadius = d=>4+d.importance*8;
    const repulsion=1500, springLen=80, springK=0.02, damping=0.85, centerGravity=0.005;

    let hovered=null, dragged=null;

    canvas.onmousemove=e=>{
        if(dragged){ dragged.x=e.offsetX; dragged.y=e.offsetY; return; }
        hovered=null;
        for(let i=nodes.length-1;i>=0;i--){
            const n=nodes[i], dx=e.offsetX-n.x, dy=e.offsetY-n.y;
            if(dx*dx+dy*dy<nodeRadius(n)*nodeRadius(n)){ hovered=n; break; }
        }
        canvas.style.cursor=hovered?'pointer':'default';
    };
    canvas.onmousedown=e=>{
        if(hovered){ dragged=hovered; hovered.vx=0; hovered.vy=0; }
    };
    canvas.onmouseup=e=>{
        if(dragged===hovered){ try{webkit.messageHandlers.nodeTap.postMessage(dragged.nodeId)}catch(e){} }
        dragged=null;
    };
    canvas.onmouseleave=()=>{ dragged=null; hovered=null; };

    function tick(){
        for(let i=0;i<nodes.length;i++){
            for(let j=i+1;j<nodes.length;j++){
                const a=nodes[i], b=nodes[j], dx=b.x-a.x, dy=b.y-a.y, dist=Math.max(1,Math.sqrt(dx*dx+dy*dy));
                const force=repulsion/(dist*dist);
                a.vx-=dx/dist*force; a.vy-=dy/dist*force;
                b.vx+=dx/dist*force; b.vy+=dy/dist*force;
            }
        }
        for(const e of edges){
            const dx=e.t.x-e.s.x, dy=e.t.y-e.s.y, dist=Math.max(1,Math.sqrt(dx*dx+dy*dy));
            const force=(dist-springLen)*springK;
            e.s.vx+=dx/dist*force; e.s.vy+=dy/dist*force;
            e.t.vx-=dx/dist*force; e.t.vy-=dy/dist*force;
        }
        for(const n of nodes){
            if(n===dragged) continue;
            n.vx+=(W/2-n.x)*centerGravity;
            n.vy+=(H/2-n.y)*centerGravity;
            n.vx*=damping; n.vy*=damping;
            n.x+=n.vx; n.y+=n.vy;
            n.x=Math.max(nodeRadius(n),Math.min(W-nodeRadius(n),n.x));
            n.y=Math.max(nodeRadius(n),Math.min(H-nodeRadius(n),n.y));
        }
    }

    function draw(){
        ctx.clearRect(0,0,W,H);
        for(const e of edges){
            ctx.beginPath(); ctx.moveTo(e.s.x,e.s.y); ctx.lineTo(e.t.x,e.t.y);
            ctx.strokeStyle='rgba(255,255,255,0.15)'; ctx.lineWidth=1+e.weight*1.5; ctx.stroke();
        }
        for(const n of nodes){
            const r=nodeRadius(n);
            ctx.beginPath(); ctx.arc(n.x,n.y,r,0,Math.PI*2);
            ctx.fillStyle=colorFor(n.group); ctx.globalAlpha=n===hovered?1:0.85; ctx.fill();
            ctx.globalAlpha=1;
            if(n===hovered||n.importance>0.7){
                ctx.strokeStyle='#fff'; ctx.lineWidth=2; ctx.stroke();
            }
            const label=n.label.substring(0,20);
            ctx.font='11px system-ui'; ctx.fillStyle='rgba(255,255,255,0.85)';
            ctx.textAlign='center'; ctx.fillText(label,n.x,n.y+r+12);
        }
    }

    function loop(){
        for(let i=0;i<3;i++) tick();
        draw();
        requestAnimationFrame(loop);
    }
    loop();
    </script></body></html>
    """
}
