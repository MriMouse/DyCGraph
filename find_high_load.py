import sys
from collections import Counter

def find_top_vertices(filename, top_n=10):
    print(f"Reading {filename}...")
    out_degree = Counter()
    in_degree = Counter()
    
    with open(filename, 'r') as f:
        for i, line in enumerate(f):
            if i % 10000000 == 0 and i > 0:
                print(f"  Processed {i} lines...")
            parts = line.strip().split()
            if len(parts) >= 2:
                u, v = parts[0], parts[1]
                out_degree[u] += 1
                in_degree[v] += 1
                
    print("\nTop 10 vertices by Out-Degree (good as source for BFS/SSSP):")
    for v, count in out_degree.most_common(top_n):
        print(f"Vertex: {v}, Out-Degree: {count}, In-Degree: {in_degree[v]}")
        
    print("\nTop 10 vertices by In-Degree:")
    for v, count in in_degree.most_common(top_n):
        print(f"Vertex: {v}, In-Degree: {count}, Out-Degree: {out_degree[v]}")

if __name__ == '__main__':
    find_top_vertices('data/input_wiki_50p_100k.txt')
