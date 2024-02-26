/*!
 g++ -O3 -fPIC -shared OMP-cantera.cpp -fopenmp -lcantera -lpthread -o libchem.so
 */

#include "cantera/zerodim.h"

#include <omp.h>

#include <chrono>

using namespace Cantera;


extern "C" {
    void run(int, int, double, double*, double, double, double, char*, int);
}

void run(int nPoints, int Nspecs, double dt, double* inputs, double T_criteria, double rtol, double atol, char* mech, int Nthreads)
{
    omp_set_num_threads(Nthreads);
    int nThreads = Nthreads;
    printf("Call cantera-c++. Running on %d threads\n", nThreads);

    // Containers for Cantera objects to be used in different. Each thread needs
    // to have its own set of linked Cantera objects. Multiple threads accessing
    // the same objects at the same time will cause errors.
    vector<shared_ptr<Solution>> sols;
    vector<unique_ptr<IdealGasReactor>> reactors;
    vector<unique_ptr<ReactorNet>> nets;

    // Create and link the Cantera objects for each thread. This step should be
    // done in serial
    for (int i = 0; i < nThreads; i++) {
        auto sol = newSolution(mech, "gas", "none");
        sols.emplace_back(sol);
        reactors.emplace_back(new IdealGasReactor());
        nets.emplace_back(new ReactorNet());
        reactors.back()->insert(sol);
        nets.back()->addReactor(*reactors.back());
    }

    // Calculate the ignition using multiple threads.
    //
    // Note on 'schedule(static, 1)':
    // This option causes points [0, nThreads, 2*nThreads, ...] to be handled by
    // the same thread, rather than the default behavior of one thread handling
    // points [0 ... nPoints/nThreads]. This helps balance the workload for each
    // thread in cases where the workload is biased. For example, calculations for low
    // T0 take longer than calculations for high T0.
    vector<double> T0(nPoints);
    vector<double> P0(nPoints);
    vector<vector<double>> Y0(nPoints, vector<double>(Nspecs+2, 0.0));
    #pragma omp parallel for schedule(static, 1)
    for (int i = 0; i < nPoints; i++) {
        // Get the Cantera objects that were initialized for this thread
        size_t j = omp_get_thread_num();
        auto gas = sols[j]->thermo();
        Reactor& reactor = *reactors[j];
        ReactorNet& net = *nets[j];

        net.setTolerances(rtol, atol);

        // Set up the problem
        double T = inputs[i*(Nspecs+2)];
        if (T >= T_criteria) {
            double P = inputs[i*(Nspecs+2)+1];
            double* tmp = new double[Nspecs];
            for (int j=0; j<Nspecs; ++j) {
                tmp[j] = inputs[i*(Nspecs+2)+j+2];
            }   
            gas->setState_TPY(T, P, tmp);
            reactor.syncState();
            net.setInitialTime(0.0);
            net.advance(dt);
            // reactor.syncState();
            inputs[i*(Nspecs+2)] = gas->temperature();
            inputs[i*(Nspecs+2)+1] = gas->pressure();
            T0[i] = gas->temperature();
            P0[i] = gas->pressure();
            const double* tmp2 = gas->massFractions();
            for (int j=0; j<Nspecs; j++)
            {
                inputs[i*(Nspecs+2)+j+2] = tmp2[j];
                Y0[i][j] = tmp2[j];
            }
        }
    }

    // Print the computed ignition delays
    printf("  T (K)    t_ig (s)\n");
    printf("--------  ----------\n");
    for (int i = 0; i < nPoints; i++) {
        printf("%8.1f  %10.3e\n", T0[i], P0[i]);
        // for (int j=0; j<Nspecs; j++)
        // {
        //     printf("%8.5f\t", Y0[i][j]);
        // }
        // printf("\n");
    }
}

int main()
{
    int nPoints = 500;
    int Nspecs = 20;
    double dt = 1e-1;
    int nthreads = 24;
    double T_criteria = 300;
    double rtol = 1e-6;
    double atol = 1e-6;

    double* inputs = new double[nPoints*(Nspecs+2)];
    for (int i = 0; i < nPoints; i++) {
        inputs[i*(Nspecs+2)] = 800 + 500 * ((float) i) / ((float) nPoints);
        inputs[i*(Nspecs+2)+1] = 101325*200 + 500 * ((float) i) / ((float) nPoints);

        for (int j=0; j<Nspecs; j++) {
            inputs[i*(Nspecs+2) + j+2] = 0.0;
        }
        inputs[i*(Nspecs+2) + 5] = 0.7;
        inputs[i*(Nspecs+2) + 12] = 0.3;
    }

    auto start_t = std::chrono::system_clock::now();
    run(nPoints, Nspecs, dt, inputs, T_criteria, rtol, atol, "../NN/CH4/drm19.yaml", nthreads);
    auto end_t = std::chrono::system_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end_t-start_t);
    std::cout << double(duration.count())*std::chrono::microseconds::period::num/std::chrono::microseconds::period::den/50*1000 << std::endl;
}