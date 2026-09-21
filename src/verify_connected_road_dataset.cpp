#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <numeric>
#include <stdexcept>
#include <unordered_map>
#include <vector>
#include <nlohmann/json.hpp>

namespace fs = std::filesystem;
using Json = nlohmann::json;
uint64_t Key(uint32_t u, uint32_t v) { return (uint64_t(std::min(u,v)) << 32) | std::max(u,v); }
void Require(bool condition, const char *message) { if (!condition) throw std::runtime_error(message); }
class Dsu {
public:
    explicit Dsu(uint32_t n) : parent_(size_t(n)+1), size_(size_t(n)+1,1) {
        std::iota(parent_.begin(),parent_.end(),0);
    }
    uint32_t Find(uint32_t v) {
        while (parent_[v] != v) { parent_[v] = parent_[parent_[v]]; v = parent_[v]; }
        return v;
    }
    void Join(uint32_t u, uint32_t v) {
        u=Find(u); v=Find(v);
        Require(u!=v,"Backbone contains a cycle");
        if(size_[u]<size_[v]) std::swap(u,v);
        parent_[v]=u; size_[u]+=size_[v];
    }
    uint32_t Size(uint32_t v) { return size_[Find(v)]; }
private:
    std::vector<uint32_t> parent_,size_;
};

int main(int argc, char **argv) {
    try {
        Require(argc==2,"Usage: verify_connected_road_dataset DATASET_DIRECTORY");
        const fs::path directory=argv[1];
        std::ifstream metadata_file(directory/"metadata.json");
        Json metadata; metadata_file>>metadata;
        const uint32_t n=metadata.at("matrix_vertices"), source=metadata.at("source_node");
        Require(source>0 && source<=n,"Invalid source");
        Json report={{"state","passed"},{"ratios",Json::array()}};
        for(const auto &ratio:metadata.at("ratios")) {
            const uint32_t percent=ratio.at("base_percent");
            const fs::path root=directory/(std::to_string(percent)+"p");
            Dsu dsu(n);
            std::vector<uint64_t> protected_keys,base_keys;
            std::ifstream backbone(root/"backbone.bin",std::ios::binary);
            Require(bool(backbone),"Missing backbone");
            uint32_t u,v;
            while(backbone.read(reinterpret_cast<char *>(&u),sizeof(u))) {
                Require(bool(backbone.read(reinterpret_cast<char *>(&v),sizeof(v))),"Truncated backbone");
                Require(u>0 && u<v && v<=n,"Invalid backbone edge");
                uint64_t key=Key(u,v);
                Require(protected_keys.empty() || protected_keys.back()<key,"Duplicate/unsorted backbone");
                protected_keys.push_back(key); dsu.Join(u,v);
            }
            Require(backbone.eof() && backbone.gcount()==0,"Partial backbone record");
            Require(protected_keys.size()==ratio.at("protected_tree_edges").get<uint64_t>(),"Backbone count mismatch");
            const auto first_input=root/ratio.at("configs").at(0).at("input_file").get<std::string>();
            std::ifstream base(first_input);
            Require(bool(base),"Missing base");
            uint32_t reverse_u,reverse_v;
            std::vector<uint8_t> active(size_t(n)+1,0);
            uint32_t active_count=0;
            while(base>>u>>v) {
                Require(bool(base>>reverse_u>>reverse_v),"Truncated reverse base record");
                Require(u>0 && u<v && v<=n && reverse_u==v && reverse_v==u,"Invalid symmetric base pair");
                uint64_t key=Key(u,v);
                Require(base_keys.empty() || base_keys.back()<key,"Duplicate/unsorted base edge");
                base_keys.push_back(key);
                Require(dsu.Find(u)==dsu.Find(v),"Base edge escapes connected backbone component");
                if(!active[u]) {active[u]=1; ++active_count;}
                if(!active[v]) {active[v]=1; ++active_count;}
            }
            Require(base.eof(),"Malformed base file");
            Require(base_keys.size()==ratio.at("base_undirected_edges").get<uint64_t>(),"Base edge count mismatch");
            Require(std::includes(base_keys.begin(),base_keys.end(),protected_keys.begin(),protected_keys.end()),"Backbone missing from base");
            Require(dsu.Size(source)==ratio.at("source_reachable_vertices").get<uint32_t>(),"Source reachability mismatch");
            Json checked={{"percent",percent},{"active_vertices",active_count},
                {"source_reachable_vertices",dsu.Size(source)}, {"base_pairs",base_keys.size()},
                {"protected_pairs",protected_keys.size()}, {"configs",Json::array()}};
            for(const auto &config:ratio.at("configs")) {
                const fs::path input=root/config.at("input_file").get<std::string>();
                Require(fs::equivalent(input,first_input),"Scale base does not share certified initial graph");
                std::ifstream update(root/config.at("update_file").get<std::string>());
                std::ifstream sizes(root/config.at("stream_size_file").get<std::string>());
                Require(bool(update) && bool(sizes),"Missing update files");
                const uint32_t scale=config.at("batch_size_directed_records"), batches=metadata.at("batches");
                std::unordered_map<uint64_t,bool> difference;
                struct Operation { uint64_t key; uint8_t bit; };
                std::vector<Operation> operations;
                operations.reserve(scale);
                Json verified_batches=Json::array();
                for(uint32_t batch=0;batch<batches;++batch) {
                    uint32_t adds,dels;
                    Require(bool(sizes>>adds>>dels) && adds==scale/2 && dels==scale/2,"Invalid batch sizes");
                    operations.clear();
                    for(uint32_t i=0;i<scale;++i) {
                        char op; uint32_t weight;
                        Require(bool(update>>op>>u>>v>>weight),"Incomplete update stream");
                        Require((op=='a'||op=='d') && weight==1 && u>0 && v>0 && u<=n && v<=n && u!=v,"Invalid update");
                        Require(active[u] && active[v] && dsu.Find(u)==dsu.Find(v),"Update outside protected core");
                        const uint8_t bit=uint8_t((u<v?1:2) << (op=='a'?2:0));
                        operations.push_back({Key(u,v),bit});
                    }
                    std::sort(operations.begin(),operations.end(),[](auto a,auto b){return a.key<b.key;});
                    uint32_t add_pairs=0,del_pairs=0,source_deletes=0,source_adds=0;
                    for(size_t i=0;i<operations.size();) {
                        size_t j=i;
                        uint8_t mask=0;
                        const uint64_t key=operations[i].key;
                        while(j<operations.size() && operations[j].key==key) {
                            Require(!(mask & operations[j].bit),"Duplicate directed update");
                            mask |= operations[j++].bit;
                        }
                        Require(j-i==2 && (mask==3 || mask==12),"Asymmetric update or within-batch cancellation");
                        const bool initial=std::binary_search(base_keys.begin(),base_keys.end(),key);
                        const auto found=difference.find(key);
                        const bool present=found==difference.end()?initial:found->second;
                        const bool add=mask==12;
                        Require(add?!present:present,"Non-effective insertion/deletion");
                        Require(!std::binary_search(protected_keys.begin(),protected_keys.end(),key),"Protected tree update");
                        if(add==initial) difference.erase(key); else difference[key]=add;
                        const bool in_source=dsu.Find(uint32_t(key>>32))==dsu.Find(source);
                        if(add) {++add_pairs; source_adds+=in_source;} else {++del_pairs; source_deletes+=in_source;}
                        i=j;
                    }
                    Require(add_pairs==scale/4 && del_pairs==scale/4,"Unbalanced effective updates");
                    const auto &expected=config.at("batches").at(batch);
                    Require(source_deletes==expected.at("source_reachable_delete_pairs").get<uint32_t>() &&
                            source_adds==expected.at("source_reachable_add_pairs").get<uint32_t>(),"Coverage mismatch");
                    verified_batches.push_back({{"batch",batch},{"effective_delete_pairs",del_pairs},
                        {"effective_add_pairs",add_pairs},{"source_reachable_delete_pairs",source_deletes},
                        {"source_reachable_add_pairs",source_adds},{"connectivity_preserved",true}});
                }
                std::string extra;
                Require(!(update>>extra) && !(sizes>>extra),"Unexpected trailing records");
                checked["configs"].push_back({{"scale",scale},{"batches",verified_batches}});
                std::cout<<"Verified "<<percent<<"p "<<scale<<" x "<<batches<<std::endl;
            }
            report["ratios"].push_back(checked);
        }
        std::ofstream output(directory/"verification.json"); output<<report.dump(2)<<'\n';
        Require(bool(output),"Cannot write verification report");
    } catch(const std::exception &error) {std::cerr<<error.what()<<std::endl; return 1;}
}
