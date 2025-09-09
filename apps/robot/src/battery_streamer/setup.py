from setuptools import setup

package_name = 'battery_streamer'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages',
         ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
    ],
    install_requires=['setuptools', 'pyserial'],
    zip_safe=True,
    maintainer='Kaan',
    maintainer_email='you@example.com',
    description='Battery telemetry UDP streamer controlled by a TCP session.',
    license='MIT',
    tests_require=['pytest'],
    entry_points={
        'console_scripts': [
            'battery_udp_node = battery_streamer.battery_udp_node:main',
        ],
    },
)
