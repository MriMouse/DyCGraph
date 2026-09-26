import it.unimi.dsi.webgraph.*;
import java.io.*;
/** Sequential WebGraph decoder; writes little-endian packed uint32 pairs to stdout. */
public class PaperUkEdges {
 public static void main(String[] args) throws Exception {
  ImmutableGraph graph=BVGraph.loadSequential(args[0]);
  NodeIterator it=graph.nodeIterator();
  BufferedOutputStream out=new BufferedOutputStream(System.out,8<<20);
  byte[] block=new byte[8<<20];int at=0;long edges=0;
  while(it.hasNext()) {int u=it.nextInt(),degree=it.outdegree();int[] a=it.successorArray();for(int j=0;j<degree;j++) {
   int v=a[j];for(int k=0;k<4;k++)block[at++]=(byte)(u>>>(8*k));for(int k=0;k<4;k++)block[at++]=(byte)(v>>>(8*k));
   if(at==block.length){out.write(block);at=0;}edges++;
  }}if(at>0)out.write(block,0,at);out.flush();System.err.println("decoded UK edges="+edges);
 }
}
