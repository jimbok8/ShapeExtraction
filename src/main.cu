#include "PointCloud.hpp"
#include "DataIO.hpp"
#include "RadixTree.hpp"
#include "Octree.hpp"
#include "NormalEstimation.hpp"
#include "CudaCommon.hpp"

#include <mpi.h>

#include <memory>
#include <iostream>
#include <chrono>

using std::cout;
using std::endl;

void bcastOctree(const int rank, OT::Octree& octree) {
    // broadcast number of points and nodes
    int n_pts = octree.n_pts;
    int n_nodes = octree.n_nodes;
    MPI_Bcast(&n_pts, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(&n_nodes, 1, MPI_INT, 0, MPI_COMM_WORLD);

    // allocate points and nodes arrays on host
    std::shared_ptr<std::vector<Point>> h_points;
    auto h_nodes = std::make_shared<std::vector<OT::OTNode>>(n_nodes);
    // copy nodes from device to host
    if (rank == 0) {
        std::cout << "Octree has " << n_nodes << " nodes" << std::endl;
        CudaCheckCall(cudaMemcpy(&(*h_nodes)[0], octree.u_nodes, n_nodes * sizeof(*octree.u_nodes), cudaMemcpyDeviceToHost));
        h_points = octree.h_points;
    }
    else {
        // only allocate new space if not rank 0, because rank 0 already has this allocated
        h_points = std::make_shared<std::vector<Point>>(n_pts);
    }


    MPI_Bcast(&(*h_nodes)[0], n_nodes, OT::OTNode::getMpiDatatype(), 0, MPI_COMM_WORLD);
    MPI_Bcast(&(*h_points)[0], n_pts, Point::getMpiDatatype(), 0, MPI_COMM_WORLD);

    if (rank != 0) {
        octree = OT::Octree(h_nodes, n_nodes, h_points, n_pts);
    }

    // unneeded memory will be freed automatically, since we used shared pointers
}


int main(int argc, char* argv[]) {
    std::string out_file_name("cloud.ply");
    std::string in_file_name("../../data/semantic3d/cathedral1_kitti.bin");
    if (argc > 1) {
        out_file_name = std::string(argv[1]);
    }
    if (argc > 2) {
        in_file_name = std::string(argv[2]);
    }

    MPI_Init(NULL, NULL);
    int n_nodes, rank;
    MPI_Comm_size(MPI_COMM_WORLD, &n_nodes);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);

    OT::Octree octree;
    // Only one node needs to compute the octree
    if (rank == 0) {
        auto input_cloud = DataIO::loadFile(in_file_name);
        // auto input_cloud = DataIO::loadKitti("../../data/kitti/2011_09_26/2011_09_26_drive_0002_sync/velodyne_points/data/0000000000.bin", 1000000);
        // auto input_cloud = DataIO::loadObj("../../data/test_sphere.obj");
        // auto input_cloud = DataIO::loadSemantic3D("../../data/semantic3d/stgallencathedral_station1_intensity_rgb.txt");
        // auto input_cloud = DataIO::loadKitti("../../data/semantic3d/cathedral1_kitti.bin", 124719076);
        std::cout << "Input data has " << input_cloud.x_vals.size() << " points" << std::endl;
        // DataIO::saveKitti(input_cloud, "../../data/semantic3d/cathedral1_kitti.bin");
        // auto reloaded = DataIO::loadKitti("../../data/semantic3d/cathedral1_kitti.bin");
        // auto input_cloud = DataIO::loadKitti("../../data/semantic3d/cathedral1_kitti.bin");
        // std::cout << "reloaded data has " << reloaded.x_vals.size() << " points" << std::endl;

        auto start_time = std::chrono::high_resolution_clock::now();
        RT::RadixTree radix_tree(input_cloud);
        auto end_time = std::chrono::high_resolution_clock::now();
        std::cout << "Radix tree construction took " << std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time).count() << "ms" << std::endl;

        start_time = std::chrono::high_resolution_clock::now();
        octree = OT::Octree(radix_tree);
        end_time = std::chrono::high_resolution_clock::now();
        std::cout << "Octree construction took " << std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time).count() << "ms" << std::endl;
    }

    auto start_time = std::chrono::high_resolution_clock::now();
    // Share constructed octree
    bcastOctree(rank, octree);
    auto end_time = std::chrono::high_resolution_clock::now();
    std::cout << "Took " << std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time).count() << "ms to send octree" << std::endl;

    start_time = std::chrono::high_resolution_clock::now();
    int total_pts = octree.n_pts;
    std::vector<int> send_counts(n_nodes);
    std::vector<int> displacements(n_nodes);
    int cnt_so_far = 0;
    int n_extra = total_pts % n_nodes;
    for (int i = 0; i < n_nodes; ++i) {
        displacements[i] = cnt_so_far;
        send_counts[i] = total_pts / n_nodes + (rank < n_extra);
        cnt_so_far += send_counts[i];
    }
    auto local_normals = NormalEstimation::estimateNormals<8>(octree, displacements[rank], send_counts[rank]);
    end_time = std::chrono::high_resolution_clock::now();

    std::vector<Point> all_normals(rank == 0 ? total_pts : 0);
    MPI_Gatherv(&local_normals[0], send_counts[rank], Point::getMpiDatatype(), rank == 0 ? &all_normals[0] : nullptr, &send_counts[0], &displacements[0], Point::getMpiDatatype(), 0, MPI_COMM_WORLD);

    auto total_time = std::chrono::high_resolution_clock::now() - start_time;
    std::cout << "Node " << rank << ": " << "Normal estimation took " << std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time).count() << "ms" << std::endl;

    if (rank == 0) {
        std::cout << "Total normal estimation time took " << std::chrono::duration_cast<std::chrono::milliseconds>(total_time).count() << "ms" << std::endl;

        PointCloud<float> output_cloud(octree.h_points, all_normals);
        output_cloud.saveAsPly(out_file_name);
    }

    return MPI_Finalize();
}
