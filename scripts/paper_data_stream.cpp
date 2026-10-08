// Streaming backend for prepare_paper_data.py. C++17, one thread, bounded memory.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
using U=uint64_t;
struct Pick { U index; uint32_t kind, rank; };
struct Edge { uint32_t u=0,v=0; };
static uint32_t parse_uint(const char*&p){ while(*p==' '||*p=='\t')++p; uint64_t n=0; if(*p<'0'||*p>'9')throw std::runtime_error("bad edge line"); while(*p>='0'&&*p<='9'){n=n*10+(*p++-'0');if(n>UINT32_MAX)throw std::runtime_error("vertex ID > uint32");} return (uint32_t)n; }
struct Reader {
 FILE* f; std::string mode; char* line=nullptr; size_t cap=0; bool header=false; U seen=0;
 Reader(const char*path,std::string m):mode(m){f=strcmp(path,"-")==0?stdin:fopen(path, m=="bin"||m=="pipe"?"rb":"r");if(!f)throw std::runtime_error("cannot open source");setvbuf(f,nullptr,_IOFBF,8<<20);}
 ~Reader(){if(line)free(line);if(f&&f!=stdin)fclose(f);}
 bool next(Edge&e){
  if(mode=="bin"||mode=="pipe"){uint64_t x;if(fread(&x,8,1,f)!=1)return false;if(mode=="bin"){e.u=x>>32;e.v=(uint32_t)x;}else{e.u=(uint32_t)x;e.v=x>>32;}++seen;return true;}
  while(getline(&line,&cap,f)>0){if(line[0]=='#'||line[0]=='%'||line[0]=='\n'||line[0]=='\r')continue;const char*p=line; if(mode=="mtx"&&!header){header=true;continue;} e.u=parse_uint(p);e.v=parse_uint(p);++seen;return true;}return false;
 }
};
struct Writer {FILE*f;std::vector<char> buf; Writer(const std::string&path):buf(8<<20){f=fopen(path.c_str(),"wb");if(!f)throw std::runtime_error("cannot open output "+path);setvbuf(f,buf.data(),_IOFBF,buf.size());} ~Writer(){if(f)fclose(f);} void edge(const Edge&e){if(fprintf(f,"%u %u\n",e.u,e.v)<0)throw std::runtime_error("write failed");} void close(){if(fflush(f)||fclose(f))throw std::runtime_error("output close failed");f=nullptr;}};
static inline U rng(U&x){x+=0x9e3779b97f4a7c15ULL;U z=x;z=(z^(z>>30))*0xbf58476d1ce4e5b9ULL;z=(z^(z>>27))*0x94d049bb133111ebULL;return z^(z>>31);}
struct Rmat {U state;int scale; U seen=0;Rmat(U seed,int s):state(seed),scale(s){} bool next(Edge&e){e={};for(int b=scale-1;b>=0;--b){double q=(rng(state)>>11)*0x1.0p-53;if(q>=.76)e.u|=1u<<b;if((q>=.57&&q<.76)||q>=.95)e.v|=1u<<b;}++seen;return true;}};
int main(int argc,char**argv){try{
 if(argc<2)throw std::runtime_error("missing command");
 std::string cmd=argv[1];
 if(cmd=="count"){if(argc!=4)throw std::runtime_error("count path mode");Reader r(argv[2],argv[3]);Edge e;U n=0;while(r.next(e))++n;std::cout<<n<<"\n";return 0;}
 if(argc!=9&&argc!=10)throw std::runtime_error("generate source mode picks outdir edges seed scale [insertion_percent]");
 std::string source=argv[2],mode=argv[3],out=argv[5];U total=std::stoull(argv[6]),seed=std::stoull(argv[7]);int scale=std::stoi(argv[8]);
 int percent=argc==10?std::stoi(argv[9]):50;
 if(percent<0||percent>100)throw std::runtime_error("insertion_percent outside [0,100]");
 std::ifstream pf(argv[4],std::ios::binary|std::ios::ate);if(!pf)throw std::runtime_error("missing picks");auto sz=pf.tellg();if(sz%sizeof(Pick))throw std::runtime_error("bad picks file");pf.seekg(0);std::vector<Pick> picks((size_t)sz/sizeof(Pick));pf.read((char*)picks.data(),sz);if(!std::is_sorted(picks.begin(),picks.end(),[](auto&a,auto&b){return a.index<b.index;}))throw std::runtime_error("unsorted picks");
 constexpr int ns=3;const int batch[ns]={1000,10000,100000};int adds[ns],dels[ns];for(int j=0;j<ns;++j){adds[j]=batch[j]*percent/100;dels[j]=batch[j]-adds[j];}
 std::vector<Edge> ins(adds[2]*10),del(dels[2]*10);
 if(picks.size()!=ins.size()+del.size())throw std::runtime_error("pick count mismatch");
 std::vector<bool> ins_seen(ins.size()),del_seen(del.size());
 for(size_t i=0;i<picks.size();++i){auto&p=picks[i];if(p.index>=total||(i&&p.index==picks[i-1].index)||p.kind>1||p.rank>=(p.kind==0?ins.size():del.size()))throw std::runtime_error("invalid pick index, kind or rank");auto&seen=p.kind==0?ins_seen:del_seen;if(seen[p.rank])throw std::runtime_error("duplicate pick rank");seen[p.rank]=true;}
 std::vector<Writer*> outs;for(auto s:{"1k","10k","100k"})outs.push_back(new Writer(out+"/input_"+s+".txt.part"));
 // Dense sorted remapping for sparse-ID TW/FS; the bitset avoids a 4 GiB ID array.
 std::vector<U> bits,prefix; if(mode=="bin"||mode=="friendster"){
  bits.resize((1000000000ULL+63)/64);Reader r(source.c_str(),mode=="friendster"?"text":mode);Edge e;while(r.next(e)){if(e.u>=1000000000u||e.v>=1000000000u)throw std::runtime_error("sparse ID >= 1e9");bits[e.u>>6]|=1ULL<<(e.u&63);bits[e.v>>6]|=1ULL<<(e.v&63);}if(r.seen!=total)throw std::runtime_error("source edge count changed in map pass");prefix.resize(bits.size()+1);for(size_t i=0;i<bits.size();++i)prefix[i+1]=prefix[i]+__builtin_popcountll(bits[i]);std::cerr<<"dense vertices="<<prefix.back()<<"\n";
 }
 auto mapped=[&](uint32_t x){return bits.empty()?x:(uint32_t)(prefix[x>>6]+__builtin_popcountll(bits[x>>6]&((1ULL<<(x&63))-1)));};
 auto handle=[&](U i,Edge e,size_t&pos){e.u=mapped(e.u);e.v=mapped(e.v);int insrank=adds[2]*10;while(pos<picks.size()&&picks[pos].index==i){auto&p=picks[pos++];if(p.kind==0){ins[p.rank]=e;insrank=p.rank;}else del[p.rank]=e;}for(int j=0;j<ns;++j)if(insrank>=adds[j]*10)outs[j]->edge(e);if((i+1)%100000000==0)std::cerr<<"processed="<<(i+1)<<"/"<<total<<"\n";};
 size_t pos=0;if(mode=="rmat"){Rmat r(seed,scale);for(U i=0;i<total;++i){Edge e;r.next(e);handle(i,e,pos);}}else{Reader r(source.c_str(),mode=="friendster"?"text":mode);Edge e;for(U i=0;i<total;++i){if(!r.next(e))throw std::runtime_error("source shorter than expected");handle(i,e,pos);}if(r.next(e))throw std::runtime_error("source longer than expected");}
 if(pos!=picks.size())throw std::runtime_error("unmatched picks");
 for(auto*w:outs){w->close();delete w;}
 // Update operations are shuffled within each batch with a deterministic local RNG.
 for(int j=0;j<ns;++j){int per=batch[j],add_count=adds[j],del_count=dels[j];std::string suffix=j==0?"1k":j==1?"10k":"100k";Writer update(out+"/update_"+suffix+".txt.part");U state=seed+uint64_t(j)*137;std::vector<int> order(per);for(int b=0;b<10;++b){for(int q=0;q<per;++q)order[q]=q;for(int q=per-1;q>0;--q)std::swap(order[q],order[rng(state)%(q+1)]);for(int q:order){bool add=q<add_count;Edge e=add?ins[b*add_count+q]:del[b*del_count+q-add_count];if(fprintf(update.f,"%c %u %u 1\n",add?'a':'d',e.u,e.v)<0)throw std::runtime_error("update write failed");}}update.close();}
 std::cerr<<"completed source_edges="<<total<<"\n";return 0;
 }catch(const std::exception&e){std::cerr<<"ERROR: "<<e.what()<<"\n";return 1;}}
