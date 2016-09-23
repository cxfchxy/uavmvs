#include <iostream>

#include "fmt/format.h"

#include "util/system.h"
#include "util/arguments.h"
#include "util/file_system.h"
#include "util/choices.h"

#include "math/bspline.h"

#include "mve/camera.h"
#include "mve/mesh_io_ply.h"
#include "mve/image_io.h"

#include "cacc/util.h"
#include "cacc/math.h"
#include "cacc/tracing.h"
#include "cacc/nnsearch.h"

#include "util/io.h"
#include "util/trajectory_io.h"

#include "geom/sphere.h"
#include "geom/volume_io.h"

#include "eval/kernels.h"

struct Arguments {
    std::string proxy_mesh;
    std::string proxy_cloud;
    std::string guidance_volume;
    std::string out_trajectory;
    std::string trajectory;
    uint num_views;
    float max_distance;
    float focal_length;
};

std::vector<std::pair<uint, uint> > grid_trajectory_indices(uint width, uint height) {
    std::vector<std::pair<uint, uint> > ret;
    for (uint gy = 0; gy < (height - 1) / 3; ++gy) {
        for (uint gx = 0; gx < width - 2; ++gx) {
            uint x;
            if (gy % 2 == 0) {
                x = 1 + gx;
            } else {
                x = width - 1 - gx;
            }
            uint y = 1 + 3 * gy;

            if (gx == 0 && gy != 0) {
                ret.emplace_back(x, y - 2);
                ret.emplace_back(x, y - 1);
            } else {
                ret.emplace_back(x, y);
            }
        }
    }
    return ret;
}


Arguments parse_args(int argc, char **argv) {
    util::Arguments args;
    args.set_exit_on_error(true);
    args.set_nonopt_minnum(4);
    args.set_nonopt_maxnum(4);
    args.set_usage("Usage: " + std::string(argv[0])
        + " [OPTS] PROXY_MESH PROXY_CLOUD GUIDANCE_VOLUME OUT_TRAJECTORY");
    args.set_description("Plans a trajectory maximizing reconstructability");
    args.add_option('t', "trajectory", true,
        "Use positions from given trajectory and only optimize viewing directions.");
    args.add_option('\0', "max-distance", true, "maximum distance to surface [80.0]");
    args.add_option('\0', "focal-length", true, "camera focal length [0.86]");
    args.parse(argc, argv);

    Arguments conf;
    conf.proxy_mesh = args.get_nth_nonopt(0);
    conf.proxy_cloud = args.get_nth_nonopt(1);
    conf.guidance_volume = args.get_nth_nonopt(2);
    conf.out_trajectory = args.get_nth_nonopt(3);
    conf.max_distance = 80.0f;
    conf.num_views = 400;
    conf.focal_length = 0.86f;

    for (util::ArgResult const* i = args.next_option();
         i != 0; i = args.next_option()) {
        switch (i->opt->sopt) {
        case 't':
            conf.trajectory = i->arg;
        break;
        case '\0':
            if (i->opt->lopt == "max-distance") {
                conf.max_distance = i->get_arg<float>();
            } else {
                throw std::invalid_argument("Invalid option");
            }
        break;
        default:
            throw std::invalid_argument("Invalid option");
        }
    }

    return conf;
}

float const pi = std::acos(-1.0f);

int main(int argc, char **argv) {
    util::system::register_segfault_handler();
    util::system::print_build_timestamp(argv[0]);

    Arguments args = parse_args(argc, argv);

    std::vector<mve::CameraInfo> trajectory;
    if (args.trajectory.empty()) {
        Volume<std::uint32_t>::Ptr volume;
        try {
            volume = load_volume<std::uint32_t>(args.guidance_volume);
        } catch (std::exception& e) {
            std::cerr << "Could not load volume: " << e.what() << std::endl;
            std::exit(EXIT_FAILURE);
        }

        std::uint32_t width = volume->width();
        std::uint32_t height = volume->height();
        std::uint32_t depth = volume->depth();

        std::vector<std::pair<uint, uint> > indices = grid_trajectory_indices(width, height);

        math::BSpline<math::Vec3f> spline;
        spline.set_degree(3);

        for (std::size_t i = 0; i < indices.size(); ++i) {
            uint x, y;
            std::tie(x, y) = indices[i];
            int oz = depth - 1;
            float max = 0.0f;
            for (uint z = 0; z < depth; ++z) {
                mve::FloatImage::Ptr image = volume->at(x, y, z);
                float value = 0.0f;
                if (image != nullptr) {
                    std::vector<float> const & values = image->get_data();
                    value = *std::max_element(values.begin(), values.end());
                }
                if (value > max) {
                    max = value;
                    oz = z;
                }
            }
            spline.add_point(volume->position(x, y, oz));
        }
        spline.uniform_knots(0.0, 1.0f);

        for (float t = 0.0f; t < 1.0f; t += 1.0f / (args.num_views - 1)) {
            mve::CameraInfo cam;

            /* Initialize nadir */
            math::Matrix3f rot(0.0f);
            rot(0, 0) = 1;
            rot(1, 1) = -1;
            rot(2, 2) = -1;
            std::copy(rot.begin(), rot.end(), cam.rot);

            math::Vec3f pos = spline.evaluate(t);
            math::Vec3f trans = -rot * pos;
            std::copy(trans.begin(), trans.end(), cam.trans);

            cam.flen = args.focal_length;

            trajectory.push_back(cam);
        }
    } else {
        load_trajectory(args.trajectory, &trajectory);
    }

    cacc::select_cuda_device(3, 5);

    mve::TriangleMesh::Ptr mesh;
    try {
        mve::TriangleMesh::Ptr mesh = generate_sphere(1.0f, 3u);
    } catch (std::exception& e) {
        std::cerr << "\tCould not load mesh: "<< e.what() << std::endl;
        std::exit(EXIT_FAILURE);
    }

    std::vector<math::Vec3f> & overtices = mesh->get_vertices();
    std::vector<math::Vec3f> vertices = mesh->get_vertices();
    std::vector<float> & ovalues = mesh->get_vertex_values();
    ovalues.resize(vertices.size());

    cacc::KDTree<3u, cacc::DEVICE>::Ptr dkd_tree;
    {
        std::vector<math::Vec3f> const & verts = mesh->get_vertices();
        acc::KDTree<3u, uint>::Ptr kd_tree = acc::KDTree<3, uint>::create(verts);
        dkd_tree = cacc::KDTree<3u, cacc::DEVICE>::create<uint>(kd_tree);
    }
    cacc::nnsearch::bind_textures(dkd_tree->cdata());

    acc::BVHTree<uint, math::Vec3f>::Ptr bvh_tree;
    bvh_tree = load_mesh_as_bvh_tree(args.proxy_mesh);
    cacc::BVHTree<cacc::DEVICE>::Ptr dbvh_tree;
    dbvh_tree = cacc::BVHTree<cacc::DEVICE>::create<uint, math::Vec3f>(bvh_tree);
    cacc::tracing::bind_textures(dbvh_tree->cdata());

    cacc::PointCloud<cacc::HOST>::Ptr cloud;
    //TODO check for vertex values...
    cloud = load_point_cloud(args.proxy_cloud);
    cacc::PointCloud<cacc::DEVICE>::Ptr dcloud;
    dcloud = cacc::PointCloud<cacc::DEVICE>::create<cacc::HOST>(cloud);

    uint num_vertices = dcloud->cdata().num_vertices;
    uint max_cameras = 20;

    cacc::VectorArray<cacc::Vec3f, cacc::DEVICE>::Ptr ddir_hist;
    ddir_hist = cacc::VectorArray<cacc::Vec3f, cacc::DEVICE>::create(num_vertices, max_cameras);
    cacc::VectorArray<float, cacc::HOST>::Ptr con_hist;
    con_hist = cacc::VectorArray<float, cacc::HOST>::create(ovalues.size(), 2);
    cacc::VectorArray<float, cacc::DEVICE>::Ptr dcon_hist;
    dcon_hist = cacc::VectorArray<float, cacc::DEVICE>::create(ovalues.size(), 2);

    cacc::Image<float, cacc::DEVICE>::Ptr dhist;
    dhist = cacc::Image<float, cacc::DEVICE>::create(256, 90);
    cacc::Image<float, cacc::HOST>::Ptr hist;
    hist = cacc::Image<float, cacc::HOST>::create(256, 90);

    math::Vec3f pos;
    math::Matrix4f w2c;
    math::Matrix3f calib;
    int width = 1920;
    int height = 1080;

    int cnt = 0;
    for (mve::CameraInfo & cam : trajectory) {
        cam.fill_calibration(calib.begin(), width, height);
        cam.fill_camera_pos(pos.begin());

        cudaStream_t stream;
        cudaStreamCreate(&stream);
        {
            dim3 grid(cacc::divup(num_vertices, KERNEL_BLOCK_SIZE));
            dim3 block(KERNEL_BLOCK_SIZE);
            initialize_histogram<<<grid, block, 0, stream>>>(dcon_hist->cdata());
            populate_histogram<<<grid, block, 0, stream>>>(
                cacc::Vec3f(pos.begin()), args.max_distance,
                dbvh_tree->cdata(), dcloud->cdata(), dkd_tree->cdata(),
                ddir_hist->cdata(), dcon_hist->cdata());
        }

        #if 0
        {
            CHECK(cudaDeviceSynchronize());
            *con_hist = *dcon_hist;
            cacc::VectorArray<float, cacc::HOST>::Data data = con_hist->cdata();
            for (std::size_t i = 0; i < vertices.size(); ++i) {
                overtices[i] = vertices[i] + pos;
                ovalues[i] = data.data_ptr[i];
            }

            mve::geom::SavePLYOptions opts;
            opts.write_vertex_values = true;
            std::string filename = fmt::format("/tmp/test-sphere-hist-{:04d}.ply", cnt);
            mve::geom::save_ply_mesh(mesh, filename, opts);
        }
        #endif

        {
            dim3 grid(cacc::divup(256, KERNEL_BLOCK_SIZE), 90);
            dim3 block(KERNEL_BLOCK_SIZE);
            evaluate_histogram<<<grid, block, 0, stream>>>(cacc::Mat3f(calib.begin()), width, height,
                dkd_tree->cdata(), dcon_hist->cdata(), dhist->cdata());
        }
        #if 0
        {
            cacc::Image<float, cacc::DEVICE>::Ptr dtmp;
            dtmp = cacc::Image<float, cacc::DEVICE>::create(256, 90);

            dim3 grid(cacc::divup(256, KERNEL_BLOCK_SIZE));
            dim3 block(KERNEL_BLOCK_SIZE);
            suppress_nonmaxima<<<grid, block, 0, stream>>>(dhist->cdata(), dtmp->cdata());
            CHECK(cudaDeviceSynchronize());

            cacc::Image<float, cacc::HOST>::Ptr hist;
            hist = cacc::Image<float, cacc::HOST>::create<cacc::DEVICE>(dtmp);
            cacc::Image<float, cacc::HOST>::Data data = hist->cdata();
            mve::FloatImage::Ptr image = mve::FloatImage::create(256, 90, 1);
            for (int y = 0; y < 90; ++y) {
                for (int x = 0; x < 256; ++x) {
                    image->at(x, y, 0) = data.data_ptr[y * data.pitch / sizeof(float) + x];
                }
            }
            mve::image::save_pfm_file(image, fmt::format("/tmp/test-hist-{:04d}.pfm", cnt));
        }
        #endif

        //TODO write a kernel to select best viewing direction
        CHECK(cudaDeviceSynchronize());
        *hist = *dhist;

        cacc::Image<float, cacc::HOST>::Data hist_data = hist->cdata();

        #if 0
        mve::FloatImage::Ptr image = mve::FloatImage::create(256, 90, 1);
        for (int y = 0; y < 90; ++y) {
            for (int x = 0; x < 256; ++x) {
                image->at(x, y, 0) = hist_data.data_ptr[y * hist_data.pitch / sizeof(float) + x];
            }
        }
        mve::image::save_pfm_file(image, fmt::format("/tmp/test-hist-{:04d}.pfm", cnt));
        #endif

        float max = 0.0f;
        float theta = 0.0f;
        float phi = 0.0f;
        for (int y = 0; y < hist_data.height; ++y) {
            for (int x = 0; x < hist_data.width; ++x) {
                float v = hist_data.data_ptr[y * hist_data.pitch / sizeof(float) + x];
                if (v > max) {
                    max = v;
                    theta = (x / (float) hist_data.width) * 2.0f * pi;
                    //float theta = (y / (float) hist_data.height) * pi;
                    phi = (0.5f + (y / (float) hist_data.height) / 2.0f) * pi;
                }
            }
        }

        float ctheta = std::cos(theta);
        float stheta = std::sin(theta);
        float cphi = std::cos(phi);
        float sphi = std::sin(phi);
        math::Vec3f view_dir(ctheta * sphi, stheta * sphi, cphi);
        view_dir.normalize();

        math::Vec3f rz = view_dir;

        math::Vec3f up = math::Vec3f(0.0f, 0.0f, -1.0f);
        bool stable = abs(up.dot(rz)) < 0.99f;
        up = stable ? up : math::Vec3f(cphi, sphi, 0.0f);

        math::Vec3f rx = up.cross(rz).normalize();
        math::Vec3f ry = rz.cross(rx).normalize();

        math::Matrix3f rot;
        for (int i = 0; i < 3; ++i) {
            rot[i] = rx[i];
            rot[3 + i] = ry[i];
            rot[6 + i] = rz[i];
        }

        math::Vec3f trans = -rot * pos;
        std::copy(trans.begin(), trans.end(), cam.trans);
        std::copy(rot.begin(), rot.end(), cam.rot);

        cam.fill_world_to_cam(w2c.begin());
        {
            dim3 grid(cacc::divup(num_vertices, KERNEL_BLOCK_SIZE));
            dim3 block(KERNEL_BLOCK_SIZE);
            populate_histogram<<<grid, block, 0, stream>>>(
                cacc::Vec3f(pos.begin()), args.max_distance,
                cacc::Mat4f(w2c.begin()), cacc::Mat3f(calib.begin()), width, height,
                dbvh_tree->cdata(), dcloud->cdata(), ddir_hist->cdata()
            );
        }

        #if 0
        {
            dim3 grid(cacc::divup(256, KERNEL_BLOCK_SIZE), 90);
            dim3 block(KERNEL_BLOCK_SIZE);
            evaluate_histogram<<<grid, block, 0, stream>>>(dkd_tree->cdata(),
               dhist->cdata(), dcon_hist->cdata());
        }

        *con_hist = *dcon_hist;
        cacc::VectorArray<float, cacc::HOST>::Data data = con_hist->cdata();
        for (std::size_t i = 0; i < vertices.size(); ++i) {
            overtices[i] = vertices[i] + pos;

            float * f = data.data_ptr + data.pitch / sizeof(float) + i;
            uint32_t v = reinterpret_cast<uint32_t&>(*f);
            ovalues[i] = cacc::uint32_to_float(v);
        }

        mve::geom::SavePLYOptions opts;
        opts.write_vertex_values = true;
        std::string filename = fmt::format("/tmp/test-2d-hist-{:04d}.ply", cnt);
        mve::geom::save_ply_mesh(mesh, filename, opts);
        #endif

        CHECK(cudaDeviceSynchronize());
        cnt += 1;
    }

    save_trajectory(trajectory, args.out_trajectory);

    return EXIT_SUCCESS;
}
