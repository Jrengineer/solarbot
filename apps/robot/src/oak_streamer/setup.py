from setuptools import setup

package_name = 'oak_streamer'

setup(
    name=package_name,
    version='0.0.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
            ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools', 'depthai', 'opencv-python'],
    zip_safe=True,
    maintainer='kaanjetson',
    maintainer_email='kaanjetson@todo.todo',
    description='Oak-D S2 kamera görüntüsünü yayınlayan ROS 2 düğümü',
    license='MIT',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            'oak_streamer_node = oak_streamer.oak_streamer_node:main',
        ],
    },
)
